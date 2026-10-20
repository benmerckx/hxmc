function main() {
	Sys.println(Make.made());
	Sys.println(Errors.typeError(1 + "a" * 2));
	Sys.println(Errors.typeError(undefinedIdentifier));
	Sys.println(Errors.typeError(1 + 2));
}
