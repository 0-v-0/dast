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
	scope listener = new TcpListener(loop);

	listener.socket.reusePort = true;
	listener.bind(new InternetAddress("127.0.0.1", port));
	listener.listen(128);
	enum writeData = "HTTP/1.1 200 OK\r\nContent-Length: 13\r\n" ~
		"Connection: keep-alive\r\nContent-Type: text/plain\r\n\r\nHello, World!";
	listener.onAccept = (Socket socket) {
		auto client = new TcpStream(loop, socket);
		client.onReceived = (in ubyte[] data) {
			//debug writeln("received: ", cast(string)data);

			client.write(writeData);
		};
		client.onClosed = {
			debug writeln("The connection is closed!");
		};
		client.onError = (in char[] msg) {
			try
				writeln("Error: ", msg);
			catch (Exception) {
			}
		};
	};
	listener.start();

	writeln("The server is listening on ", listener.localAddress);
	loop.run();
}
