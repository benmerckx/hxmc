// The platform packages of @hxmc/haxe (the native compiler): hxmc's target -> npm's names
export const PLATFORMS = {
	'linux-x86_64': { pkg: '@hxmc/haxe-linux-x64', os: 'linux', cpu: 'x64', exe: 'haxe' },
	'linux-arm64': { pkg: '@hxmc/haxe-linux-arm64', os: 'linux', cpu: 'arm64', exe: 'haxe' },
	'macos-x86_64': { pkg: '@hxmc/haxe-darwin-x64', os: 'darwin', cpu: 'x64', exe: 'haxe' },
	'macos-arm64': { pkg: '@hxmc/haxe-darwin-arm64', os: 'darwin', cpu: 'arm64', exe: 'haxe' },
	'windows-x86_64': { pkg: '@hxmc/haxe-win32-x64', os: 'win32', cpu: 'x64', exe: 'haxe.exe' },
	'windows-arm64': { pkg: '@hxmc/haxe-win32-arm64', os: 'win32', cpu: 'arm64', exe: 'haxe.exe' },
};

// The runtime objects' packages (@hxmc/rt-<target>: <target>/rt.o, ssl.o and
// uv.o), one per directory of bin/hxmc/rt (the Makefile's RT_TARGETS), any of
// them installable anywhere (cross builds)
export const RT_TARGETS = [
	'linux-x86_64', 'linux-x86_64-glibc', 'linux-arm64', 'linux-arm64-glibc',
	'macos-x86_64', 'macos-arm64', 'windows-x86_64', 'windows-arm64',
	'android-arm64', 'android-x86_64',
];
