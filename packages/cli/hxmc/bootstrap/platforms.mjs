// The platform packages of @hxmc/cli: hxmc's target -> npm's names. Each holds
// the native compiler of that machine and the runtime objects (rt:
// <target>/rt.o, ssl.o, uv.o) of its targets; Linux's also those of the glibc
// mode. (Android's runtime objects are in no package: a release archive or
// a build from source.)
export const PLATFORMS = {
	'linux-x86_64': { pkg: '@hxmc/linux-x64', os: 'linux', cpu: 'x64', exe: 'haxe', rt: ['linux-x86_64', 'linux-x86_64-glibc'] },
	'linux-arm64': { pkg: '@hxmc/linux-arm64', os: 'linux', cpu: 'arm64', exe: 'haxe', rt: ['linux-arm64', 'linux-arm64-glibc'] },
	'macos-x86_64': { pkg: '@hxmc/darwin-x64', os: 'darwin', cpu: 'x64', exe: 'haxe', rt: ['macos-x86_64'] },
	'macos-arm64': { pkg: '@hxmc/darwin-arm64', os: 'darwin', cpu: 'arm64', exe: 'haxe', rt: ['macos-arm64'] },
	'windows-x86_64': { pkg: '@hxmc/win32-x64', os: 'win32', cpu: 'x64', exe: 'haxe.exe', rt: ['windows-x86_64'] },
	'windows-arm64': { pkg: '@hxmc/win32-arm64', os: 'win32', cpu: 'arm64', exe: 'haxe.exe', rt: ['windows-arm64'] },
};
