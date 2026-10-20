#!/bin/sh
# IosHello.app on an iPhone simulator (macOS with Xcode; make ios-sim-check,
# CI's ios-simulator job): the bundle checked with Apple's tools (codesign
# --verify, plutil -lint), a simulator of the newest iOS runtime and iPhone
# made and booted, the app installed and launched with its stdout in a
# file, its line there; the simulator deleted at the end.
#   sh hxmc/test/ios/ios.sh <IosHello.app> [out dir]
set -u
app=$1
out=$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)
id=org.hxmc.hello
stdout="$out/stdout.txt"
failed=0

check() {
	if [ "$2" = 0 ]; then echo "ios.sh: $1: ok"; else
		echo "ios.sh: $1: FAIL"
		failed=1
	fi
}

codesign --verify --strict --verbose=2 "$app"
check "codesign --verify" $?
plutil -lint "$app/Info.plist"
check "plutil -lint Info.plist" $?

runtime=$(xcrun simctl list runtimes available | grep -o 'com\.apple\.CoreSimulator\.SimRuntime\.iOS-[0-9-]*' | sort -t- -k2,2n -k3,3n | tail -1)
type=$(xcrun simctl list devicetypes | grep -o 'com\.apple\.CoreSimulator\.SimDeviceType\.iPhone-[0-9][0-9]*)' | tr -d ')' | sort -t- -k2,2n | tail -1)
echo "ios.sh: $type on $runtime"
udid=$(xcrun simctl create hxmc-ios-hello "$type" "$runtime")
check "a simulator made" $?
cleanup() {
	xcrun simctl shutdown "$udid" > /dev/null 2>&1
	xcrun simctl delete "$udid" > /dev/null 2>&1
}
trap cleanup EXIT
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b > /dev/null
check "booted" $?
xcrun simctl install "$udid" "$app"
check "install" $?
rm -f "$stdout" "$out/stderr.txt"
xcrun simctl launch --stdout="$stdout" --stderr="$out/stderr.txt" "$udid" $id
check "launch" $?
i=0
while [ $i -lt 60 ] && ! grep -q "hello from hxmc on" "$stdout" 2>/dev/null; do
	sleep 1
	i=$((i + 1))
done
cat "$stdout" "$out/stderr.txt" 2>/dev/null
grep -q "hello from hxmc on .*: 998001 6 boom" "$stdout"
check "its line on stdout" $?
exit $failed
