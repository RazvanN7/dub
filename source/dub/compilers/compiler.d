/**
	Compiler settings and abstraction.

	Copyright: © 2013-2016 rejectedsoftware e.K.
	License: Subject to the terms of the MIT license, as written in the included LICENSE.txt file.
	Authors: Sönke Ludwig
*/
module dub.compilers.compiler;

public import dub.compilers.buildsettings;
public import dub.platform : BuildPlatform, matchesSpecification;

import dub.internal.vibecompat.core.file;
import dub.internal.vibecompat.core.log;
import dub.internal.vibecompat.data.json;
import dub.internal.vibecompat.inet.path;
import dub.recipe.packagerecipe : ToolchainRequirements;

import std.algorithm;
import std.array;
import std.conv;
import std.exception;
import std.process;
import std.typecons : Flag;


/** Returns a compiler handler for a given binary name.

	The name will be compared against the canonical name of each registered
	compiler handler. If no match is found, the sub strings "dmd", "gdc" and
	"ldc", in this order, will be searched within the name. If this doesn't
	yield a match either, an exception will be thrown.
*/
Compiler getCompiler(string name)
{
	foreach (c; s_compilers)
		if (c.name == name)
			return c;

	// try to match names like gdmd or gdc-2.61
	if (name.canFind("dmd")) return getCompiler("dmd");
	if (name.canFind("gdc")) return getCompiler("gdc");
	if (name.canFind("ldc")) return getCompiler("ldc");

	throw new Exception("Unknown compiler: "~name);
}

/** Registers a new compiler handler.

	Note that by default `DMDCompiler`, `GDCCompiler` and `LDCCompiler` are
	already registered at startup.
*/
void registerCompiler(Compiler c)
{
	s_compilers ~= c;
}


interface Compiler {
	/// Returns the canonical name of the compiler (e.g. "dmd").
	@property string name() const;

	/** Determines the build platform properties given a set of build settings.

		This will invoke the compiler to build a platform probe file, which
		determines the target build platform's properties during compile-time.

		See_Also: `dub.compilers.utils.generatePlatformProbeFile`
	*/
	BuildPlatform determinePlatform(ref BuildSettings settings, string compiler_binary, string arch_override = null);

	/// Replaces high level fields with low level fields and converts
	/// dmd flags to compiler-specific flags
	void prepareBuildSettings(ref BuildSettings settings, BuildSetting supported_fields = BuildSetting.all) const;

	/// Removes any dflags that match one of the BuildOptions values and populates the BuildSettings.options field.
	void extractBuildOptions(ref BuildSettings settings) const;

	/// Computes the full file name of the generated binary.
	string getTargetFileName(in BuildSettings settings, in BuildPlatform platform) const;

	/// Adds the appropriate flag to set a target path
	void setTarget(ref BuildSettings settings, in BuildPlatform platform, string targetPath = null) const;

	/// Invokes the compiler using the given flags
	void invoke(in BuildSettings settings, in BuildPlatform platform, void delegate(int, string) output_callback);

	/// Invokes the underlying linker directly
	void invokeLinker(in BuildSettings settings, in BuildPlatform platform, string[] objects, void delegate(int, string) output_callback);

	/// Convert linker flags to compiler format
	string[] lflagsToDFlags(in string[] lflags) const;

	/// Get the dependency requirement string for this compiler
	string toolchainRequirementString(const ref ToolchainRequirements tr);

	/// Check whether the compiler meet the compiler requirement specified
	/// in the recipe.
	bool checkCompilerRequirement(const ref BuildPlatform platform, const ref ToolchainRequirements tr);

	/// Check if the compiler is supported by the recipe
	final bool checkCompilerSupported(const ref ToolchainRequirements tr)
	{
		const str = toolchainRequirementString(tr);
		return str != ToolchainRequirements.noKwd;
	}

	/// Check whether the compiler meet the frontend requirement specified
	/// in the recipe.
	final bool checkFrontendRequirement(const ref BuildPlatform platform, const ref ToolchainRequirements tr)
	{
		import std.typecons : Yes;

		return checkRequirement(tr.frontend, platform.frontendVersionString, Yes.dmdVer);
	}

	/// Check that a particular tool version matches with a given requirement
	final bool checkRequirement(const string requirement, const string toolVer, const Flag!"dmdVer" dmdVer)
	{
		import dub.compilers.utils : dmdLikeVersionToSemverLike;
		import dub.dependency : Dependency, Version;
		import std.algorithm : all, map, splitter;

		if (!requirement.length) return true; // no requirement

		const ver = Version(dmdVer ? dmdLikeVersionToSemverLike(toolVer) : toolVer);

		return requirement
			.splitter(' ')
			.map!(r => dmdVer ? dmdLikeVersionToSemverLike(r) : r)
			.join(' ')
			.Dependency
			.matches(ver);
	}

	/** Runs a tool and provides common boilerplate code.

		This method should be used by `Compiler` implementations to invoke the
		compiler or linker binary.
	*/
	protected final void invokeTool(string[] args, void delegate(int, string) output_callback)
	{
		import std.string;

		int status;
		if (output_callback) {
			auto result = executeShell(escapeShellCommand(args));
			output_callback(result.status, result.output);
			status = result.status;
		} else {
			auto compiler_pid = spawnShell(escapeShellCommand(args));
			status = compiler_pid.wait();
		}

		version (Posix) if (status == -9) {
			throw new Exception(format("%s failed with exit code %s. This may indicate that the process has run out of memory.",
				args[0], status));
		}
		enforce(status == 0, format("%s failed with exit code %s.", args[0], status));
	}

	/** Compiles platform probe file with the specified compiler and parses its output.
		Params:
			compiler_binary =	binary to invoke compiler with
			args			=	arguments for the probe compilation
			arch_override	=	special handler for x86_mscoff
			versionRes		=	array of regular expressions to scan the output
								and find the compiler version. For each, the
								version must be in capture index 1. The output
								is scanned in multi-line mode (i.e. ^ will match any line start)
	*/
	protected final BuildPlatform probePlatform(string compiler_binary, string[] args,
		string arch_override, string[] versionRes)
	{
		import dub.compilers.utils : generatePlatformProbeFile, readPlatformJsonProbe;
		import std.algorithm : filter, map;
		import std.range : takeOne;
		import std.regex : matchFirst, regex;
		import std.string : format;

		auto fil = generatePlatformProbeFile();

		auto result = executeShell(escapeShellCommand(compiler_binary ~ args ~ fil.toNativeString()));
		enforce(result.status == 0, format("Failed to invoke the compiler %s to determine the build platform: %s",
				compiler_binary, result.output));

		auto build_platform = readPlatformJsonProbe(result.output);
		build_platform.compilerBinary = compiler_binary;

		if (build_platform.compiler != this.name) {
			logWarn(`The determined compiler type "%s" doesn't match the expected type "%s". `~
				`This will probably result in build errors.`, build_platform.compiler, this.name);
		}

		auto ver = versionRes
			.map!(re => matchFirst(result.output, regex(re, "m")))
			.filter!(c => c.length > 1)
			.map!(c => c[1])
			.takeOne();
		if (ver.empty) {
			logWarn(`Could not probe the compiler version for "%s". ` ~
				`Toolchain requirements might be ineffective`, build_platform.compiler);
		}
		else {
			build_platform.compilerVersion = ver.front;
		}

		// Hack: see #1059
		// When compiling with --arch=x86_mscoff build_platform.architecture is equal to ["x86"] and canFind below is false.
		// This hack prevents unnesessary warning 'Failed to apply the selected architecture x86_mscoff. Got ["x86"]'.
		// And also makes "x86_mscoff" available as a platform specifier in the package recipe
		if (arch_override == "x86_mscoff")
			build_platform.architecture ~= arch_override;
		if (arch_override.length && !build_platform.architecture.canFind(arch_override)) {
			logWarn(`Failed to apply the selected architecture %s. Got %s.`,
				arch_override, build_platform.architecture);
		}

		return build_platform;
	}
}

private {
	Compiler[] s_compilers;
}
