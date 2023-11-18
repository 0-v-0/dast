module dast.ws.server;

import dast.async,
dast.async.socket,
dast.http,
dast.ws.frame,
std.socket,
std.logger,
std.conv : text;

alias
PeerID = int,
ReqHandler = void function(WebSocketServer, WSClient, in Request);

class WSClient : TcpStream {
	const(ubyte)[] data;
	Frame[] frames;
	Frame frame;

@safe:
	@property id() => cast(int)handle;

	this(EventLoop loop, Socket socket, uint bufferSize = 4 * 1024) {
		super(loop, socket, bufferSize);
	}

	void send(T)(in T msg) {
		import std.traits,
		std.string : representation;

		static if (is(T : const(char)[])) {
			auto bytes = msg.representation;
			enum op = Op.TEXT;
		} else {
			alias bytes = msg;
			enum op = Op.BINARY;
		}
		auto data = Frame(true, op, false, State.done, [0, 0, 0, 0], bytes.length, bytes).serialize;
		try {
			trace("Sending ", bytes.length, " bytes to #", id, " in one frame of ", data.length, " bytes long");
			return write(data);
		} catch (Exception) {
		}
	}

	override void close() nothrow {
		super.close();
		data = [];
		frames = [];
		frame = Frame();
	}
}

class WebSocketServer : ListenerBase {
	import tame.meta;

	mixin Forward!"_socket";

	ReqHandler handler;
	ServerSettings settings;
	uint connections;

	this(AddressFamily family = AddressFamily.INET) {
		super(new EventLoop, family);
	}

	this(EventLoop loop, AddressFamily family = AddressFamily.INET) {
		super(loop, family);
	}

	// dfmt off
	void onOpen(WSClient, in Request) nothrow {}
	void onClose(WSClient) nothrow {}
	void onTextMessage(WSClient, string) nothrow {}
	void onBinaryMessage(WSClient, const(ubyte)[]) nothrow {}

	bool add(TcpStream client) nothrow {
		if (!client.isConnected)
			return false;

		if (settings.maxConnections && connections >= settings.maxConnections) {
			try
				warning("Maximum number of connections ", settings.maxConnections, " reached");
			catch (Exception) {}
				client.close();
			return false;
		}
		connections++;
		return true;
	}
	// dfmt on

	void remove(WSClient client) nothrow {
		onClose(client);
		try
			info("Closing connection #", client.id);
		catch (Exception) {
		}
		if (client.isConnected)
			client.close();
		connections--;
	}

	void run() {
		this.reusePort = settings.reusePort;
		socket.bind(new InternetAddress("127.0.0.1", settings.port));
		socket.listen(settings.connectionQueueSize);

		info("Listening on port: ", settings.port);
		if (settings.maxConnections)
			info("Maximum allowed connections: ", settings.maxConnections);
		else
			info("Maximum allowed connections: unlimited");
		start();
		(cast(EventLoop)_inLoop).run();
	}

	override void start() {
		_inLoop.register(this);
		_isRegistered = true;
		version (Windows)
			doAccept();
	}

	protected override void onRead() {
		debug (Log)
			trace("start listening");
		if (!onAccept((Socket socket) {
				debug (Log)
					info("new connection from ", socket.remoteAddress, ", fd=", socket.handle);

				auto client = new WSClient(cast(EventLoop)_inLoop, socket, settings.bufferSize);
				client.onReceived = (in ubyte[] data)@trusted {
					onReceive(client, data);
				};
				client.onClosed = ()@trusted { remove(client); };
				client.start();
			})) {
			close();
		}
	}

nothrow:
	bool performHandshake(WSClient client, in ubyte[] msg, ref Request req) {
		import sha1ct : sha1Of;
		import std.uni : toLower;
		import tame.base64 : encode;

		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			KEY = "Sec-WebSocket-Key".toLower(),
			KEY_MAXLEN = 192 - MAGIC.length;
		client.data ~= msg;
		if (client.data.length > 2048) {
			remove(client);
			return false;
		}
		if (!req.tryParse(client.data))
			return false;

		auto key = KEY in req.headers;
		if (!key || key.length > KEY_MAXLEN) {
			if (handler)
				try
					handler(this, client, req);
				catch (Exception) {
				}
			return false;
		}
		auto len = key.length;
		char[256] buf = void;
		buf[0 .. len] = *key;
		buf[len .. len + MAGIC.length] = MAGIC;
		client.write(
			"HTTP/1.1 101 Switching Protocol\r\n" ~
				"Upgrade: websocket\r\n" ~
				"Connection: Upgrade\r\n" ~
				"Sec-WebSocket-Accept: " ~ encode(
					sha1Of(buf[0 .. len + MAGIC.length]), buf) ~
				"\r\n\r\n");
		if (client.frames)
			client.frames.length = 0;
		else {
			Frame[] frames;
			frames.reserve(1);
			client.frames = frames;
		}
		client.data = [];
		return true;
	}

	private
	void onReceive(WSClient client, in ubyte[] data) {
		import std.algorithm : swap;

		try
			trace("Received ", data.length, " bytes from ", client.id);
		catch (Exception) {
		}

		if (client.frames) {
			Frame frame = client.parse(data);
			for (;;) {
				handleFrame(client, frame);
				auto newFrame = client.parse([]);
				if (newFrame == frame)
					break;
				swap(newFrame, frame);
			}
		} else {
			Request req;
			if (performHandshake(client, data, req)) {
				try
					info("Handshake with ", client.id, " done (path=", req.path, ")");
				catch (Exception) {
				}
				onOpen(client, req);
			}
		}
	}

	void handleFrame(WSClient client, in Frame frame) {
		debug (Log)
			tracef("From client %s received frame: done=%s; fin=%s; op=%s; length=%u",
				client.id, frame.done, frame.fin, frame.op, frame.length);
		if (!frame.done)
			return;
		switch (frame.op) {
			// dfmt off
		case Op.CONT: return handleCont(client, frame);
		case Op.TEXT: return handle!false(client, frame);
		case Op.BINARY: return handle!true(client, frame);
		// dfmt on
		case Op.PING:
			enum pong = Frame(true, Op.PONG, false, State.done, [0, 0, 0, 0], 0, [
			]).serialize;
			try
				client.write(pong);
			catch (Exception) {
			}
			return;
		case Op.PONG:
			try
				trace("Received pong from ", client.id);
			catch (Exception) {
			}
			return;
		default:
			return remove(client);
		}
	}

	void handleCont(WSClient client, in Frame frame)
	in (!client.id || client.frames, text("Client #", client.id, " is used before handshake")) {
		if (!frame.fin) {
			if (frame.data.length)
				client.frames ~= frame;
			return;
		}
		auto frames = client.frames;
		Op originalOp = frames[0].op;
		size_t len;
		foreach (f; frames)
			len += f.data.length;
		const(ubyte)[] data;
		data.reserve(len + frame.data.length);
		foreach (f; frames)
			data ~= f.data;
		data ~= frame.data;
		client.frames.length = 0;
		if (originalOp == Op.TEXT)
			onTextMessage(client, cast(string)data[]);
		else if (originalOp == Op.BINARY)
			onBinaryMessage(client, data[]);
	}

	void handle(bool binary)(WSClient client, in Frame frame)
	in (!client.frames.length, "Protocol error") {
		if (frame.fin) {
			static if (binary)
				onBinaryMessage(client, frame.data);
			else
				onTextMessage(client, cast(string)frame.data);
		} else
			client.frames ~= frame;
	}
}
