import dast.http1;

void handle(Request, Response resp) {
	resp.writeHeader("HTTP/1.1 200 OK");
	resp.writeHeader("Content-Type: text/html; charset=UTF-8");
	resp.writeHeader("Connection: keep-alive");
	resp << "<h1>Hello world</h1>";
}

void main() {
	import std.parallelism;

	auto server = new Server(&handle);
	server.start(8080, totalCPUs);
}
