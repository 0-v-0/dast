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

struct WSClient {
	TcpStream client;
	alias client this;

	@property id() => cast(int)handle;

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
			return client.write(data);
		} catch (Exception) {
		}
	}
}

class WebSocketServer : ListenerBase {
	import dast.async.container;
	import tame.meta;

	mixin Forward!"_socket";

	protected Map!(PeerID, Frame[]) map;
	Map!(PeerID, WSClient) clients;
	ReqHandler handler;
	ServerSettings settings;

	this(AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		this(new EventLoop, family, bufferSize);
	}

	this(EventLoop loop, AddressFamily family = AddressFamily.INET, uint bufferSize = 4 * 1024) {
		settings.bufferSize = bufferSize;
		super(loop, family);
		map = new typeof(map);
		clients = new typeof(clients);
	}

	// dfmt off
	void onOpen(WSClient, in Request) nothrow {}
	void onClose(WSClient) nothrow {}
	void onTextMessage(WSClient, string) nothrow {}
	void onBinaryMessage(WSClient, const(ubyte)[]) nothrow {}

	void add(TcpStream client) nothrow {
		if (clients.length > settings.maxConnections) {
			try
				warning("Maximum number of connections ", settings.maxConnections, " reached");
			catch(Exception) {}
			client.close();
		} else
			clients[WSClient(client).id] = WSClient(client);
	}

	void remove(PeerID id) nothrow {
		map.remove(id);
		dataBySource.remove(id);
		frames.remove(id);
		if (auto client = clients[id]) {
			onClose(WSClient(client));
			try info("Closing connection #", id); catch(Exception) {}
			client.close();
		}
		clients.remove(id);
	}

	// dfmt on
	void run() {
		this.reusePort = settings.reusePort;
		socket.bind(new InternetAddress("127.0.0.1", settings.port));
		socket.listen(settings.connectionQueueSize);

		info("Listening on port: ", settings.port);
		info("Maximum allowed connections: ", settings.maxConnections);
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

				auto client = new TcpStream(_inLoop, socket, settings.bufferSize);
				client.onReceived = (in ubyte[] data)@trusted {
					onReceive(WSClient(client), data);
				};
				client.onClosed = ()@trusted { remove(WSClient(client).id); };
				client.start();
			})) {
			close();
		}
	}

	bool performHandshake(WSClient client, in ubyte[] msg, ref Request req) nothrow {
		import sha1ct : sha1Of;
		import std.uni : toLower;
		import tame.base64 : encode;

		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			KEY = "Sec-WebSocket-Key".toLower(),
			KEY_MAXLEN = 192 - MAGIC.length;
		const(ubyte)[] data = void;
		const id = client.id;
		if (auto p = id in dataBySource)
			data = dataBySource[id] ~= msg;
		else
			data = dataBySource[id] = msg;
		if (data.length > 2048) {
			remove(id);
			return false;
		}
		if (!req.tryParse(data))
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
		try {
			client.write(
				"HTTP/1.1 101 Switching Protocol\r\n" ~
					"Upgrade: websocket\r\n" ~
					"Connection: Upgrade\r\n" ~
					"Sec-WebSocket-Accept: " ~ encode(
						sha1Of(buf[0 .. len + MAGIC.length]), buf) ~
					"\r\n\r\n");
		} catch (Exception)
			return false;
		if (map[id])
			map[id].length = 0;
		else {
			Frame[] frames;
			frames.reserve(1);
			map[id] = frames;
		}
		dataBySource[id] = [];
		return true;
	}

private nothrow:
	void onReceive(WSClient client, in ubyte[] data) {
		import std.algorithm : swap;

		try
			trace("Received ", data.length, " bytes from ", client.id);
		catch (Exception) {
		}

		if (map[client.id].ptr) {
			const id = client.id;
			Frame prevFrame = id.parse(data);
			for (;;) {
				handleFrame(WSClient(client), prevFrame);
				auto newFrame = id.parse([]);
				if (newFrame == prevFrame)
					break;
				swap(newFrame, prevFrame);
			}
		} else {
			Request req;
			if (performHandshake(client, data, req)) {
				try
					info("Handshake with ", client.id, " done (path=", req.path, ")");
				catch (Exception) {
				}
				onOpen(WSClient(client), req);
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
			return remove(client.id);
		}
	}

	import std.array;

	void handleCont(WSClient client, in Frame frame)
	in (!client.id || map[client.id], text("Client #", client.id, " is used before handshake")) {
		if (!frame.fin) {
			if (frame.data.length)
				map[client.id] ~= frame;
			return;
		}
		auto frames = map[client.id];
		Op originalOp = frames[0].op;
		auto data = appender!(ubyte[])();
		data.reserve(frames.length);
		foreach (f; frames)
			data ~= f.data;
		data ~= frame.data;
		map[client.id].length = 0;
		if (originalOp == Op.TEXT)
			onTextMessage(client, cast(string)data[]);
		else if (originalOp == Op.BINARY)
			onBinaryMessage(client, data[]);
	}

	void handle(bool binary)(WSClient client, in Frame frame)
	in (!map[client.id].length, "Protocol error") {
		if (frame.fin) {
			static if (binary)
				onBinaryMessage(client, frame.data);
			else
				onTextMessage(client, cast(string)frame.data);
		} else
			map[client.id] ~= frame;
	}
}
