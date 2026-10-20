#!/bin/sh
# AndroidHello.apk on the device or emulator adb reaches (make
# android-device-check, CI's emulator): installed, launched, its line in
# logcat (tag hxmc); logcat to <out dir>/logcat.txt.
#   sh hxmc/test/android/android.sh <AndroidHello.apk> [out dir]
set -u
apk=$1
out=$(mkdir -p "${2:-.}" && cd "${2:-.}" && pwd)
id=org.hxmc.hello
failed=0

check() {
	if [ "$2" = 0 ]; then echo "android.sh: $1: ok"; else
		echo "android.sh: $1: FAIL"
		failed=1
	fi
}

adb wait-for-device
adb uninstall $id > /dev/null 2>&1
adb install -r "$apk"
check "install" $?
adb logcat -c
adb shell am start -W -n $id/android.app.NativeActivity
check "am start" $?
i=0
while [ $i -lt 60 ] && ! adb logcat -d -s hxmc:I | grep -q "hello from hxmc on"; do
	sleep 1
	i=$((i + 1))
done
adb logcat -d > "$out/logcat.txt"
grep "hxmc" "$out/logcat.txt" | tail -20
grep -q "hello from hxmc on .*: 998001 6 boom" "$out/logcat.txt"
check "its line in logcat" $?
exit $failed
