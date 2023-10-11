import dast.async;
import std.socket;
import std.stdio;

extern (C) __gshared {
	bool rt_cmdline_enabled = false;
	bool rt_envvars_enabled = false;
	auto rt_options = [
		"gcopt=gc:precise", "scanDataSeg=precise"
	];
}

void main() {
	enum port = 8090;
	scope loop = new EventLoop;
	scope listener = new TcpListener(loop, AddressFamily.INET);

	listener.reusePort = true;
	listener.bind(new InternetAddress("127.0.0.1", port));
	listener.listen(128);
	listener.onAccepted = (TcpListener sender, TcpStream client) {
		client.onReceived = (in ubyte[] data) {
			debug writeln("received: ", cast(string)data);

			enum writeData = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\nConnection: keep-alive\r\nContent-Type: text/plain" ~
				"\r\n\r\nHello, World!";

			client.write(cast(ubyte[])writeData, (in void[], size_t size) {
				debug writeln("sent bytes: ", size, "  content: ", writeData);
				// client.close(); // comment out for keep-alive
			});
		};
		client.onClosed = {
			debug writeln("The connection is closed!");
		};
		client.onError = (in char[] msg) { writeln("Error: ", msg); };
	};
	listener.start();

	writeln("The server is listening on ", listener.localAddress);
	loop.run();
}
