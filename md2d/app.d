import md2d : md2d;
import std.file;
import std.path;

int main(string[] args) {
	import core.stdc.stdio;

	if (args.length < 2) {
		printf("Usage: md2d <input> [output]\n\n");
		return 1;
	}

	auto file = args[1];
	write(args.length > 2 ? args[2] : setExtension(file, "d"), md2d(cast(string)read(file)));
	return 0;
}
