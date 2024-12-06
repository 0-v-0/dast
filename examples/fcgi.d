import dast.fcgi;

void handle(Request, Response resp) {
	resp.writeHeader("Status: 200");
	resp.writeHeader("Content-Type: text/html; charset=UTF-8");
	resp.write("<h1>Hello world</h1>");
}

void main() {
	import std.parallelism;

	auto fcgi = new FCGIServer(&handle);
	fcgi.start(9001, totalCPUs);
}
