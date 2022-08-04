import dast.lshttp;
import std.file;
import std.stdio;

void main() {
	enum port = 7443;

	assert(readMimeTypes(readText("mime.types")));
	mimeTypes.rehash();
	auto server = LSServer(port, &handle);
	writeln("Listening on port: ", port);
}