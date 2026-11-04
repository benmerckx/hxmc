package hxmc.com;

// A BSTR in a COM method's signature (docs/interop.md, "COM"): a String in
// Haxe, a BSTR in C (length-prefixed UTF-16, SysAllocStringLen's). A
// parameter passes a BSTR made for the call and freed after it; a result
// ([out, retval]) is the BSTR's string, the BSTR freed (SysFreeString); a
// null BSTR reads as "". A plain String parameter is an LPCWSTR (UTF-16,
// NUL-terminated) instead, and a String result an LPWSTR CoTaskMemAlloc made.
abstract BStr(String) from String to String {}
