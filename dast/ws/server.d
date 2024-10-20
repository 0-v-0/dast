module dast.ws.server;

import dast.async,
dast.http,
dast.ws.frame,
std.socket,
std.conv : text;

debug (Log) import std.logger;

public import dast.async : EventLoop, EventExecutor, Selector;

alias
PeerID = int,
NextHandler = void delegate(),
ReqHandler = void function(WebSocketServer server, WSClient client, in Request req, scope NextHandler next);

///
@safe class WSClient : TcpStream {
	const(ubyte)[] data;
	Frame[] frames;
	Frame frame;
nothrow:
	@property id() => cast(int)handle;

	this(Selector loop, Socket socket, uint bufferSize = 4 * 1024) @trusted {
		super(loop, socket, bufferSize);
		p = _rBuf.ptr;
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
		const data = Frame(true, op, false, State.done, [0, 0, 0, 0],
			bytes.length, bytes).serialize;
		write(data);
		return flush();
	}

	override void close() {
		super.close();
		data = [];
		frames = [];
		frame = Frame();
	}

private:
	bool put(size_t len) @trusted {
		if (_rBuf.ptr - p + len >= bufferSize)
			return false;
		_rBuf = _rBuf[len .. $];
		return true;
	}

	void reset() @trusted {
		_rBuf = p[0 .. _rBuf.ptr - p + _rBuf.length];
		data.length = 0;
	}

	bool tryParse(ref Request req) @trusted
		=> req.tryParse(p[0 .. _rBuf.ptr - p]);

	typeof(_rBuf.ptr) p;
}

class WebSocketServer : TcpListener {
	ReqHandler[] handlers;
	ServerSettings settings;
	uint connections;

	this(AddressFamily family = AddressFamily.INET) {
		super(new EventExecutor, family);
	}

	this(Selector loop, AddressFamily family = AddressFamily.INET) {
		super(loop, family);
	}

	void run() {
		import dast.http.server;

		bindAndListen(_socket, settings);
		if (!onAccept)
			onAccept = (Socket socket) {
			auto client = new WSClient(_inLoop, socket, settings.bufferSize);
			client.onReceived = (in ubyte[] data) @trusted {
				onReceive(client, data);
			};
			client.onClosed = () @trusted {
				if (client.id)
					remove(client);
			};
			client.start();
		};

		start();
		(cast(EventLoop)_inLoop).run();
	}

nothrow:
	// dfmt off
	void onOpen(WSClient, in Request) {}
	void onClose(WSClient) {}
	void onTextMessage(WSClient, string) {}
	void onBinaryMessage(WSClient, const(ubyte)[]) {}

	bool add(TcpStream client)
	in (client.handle) {
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

	void remove(WSClient client)
	in (client.id) {
		onClose(client);
		if (client.isConnected)
			client.close();
		connections--;
	}

	bool performHandshake(WSClient client, in ubyte[] msg, ref Request req) {
		import sha1ct : sha1Of;
		import std.uni : toLower;
		import tame.base64 : encode;

		enum MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11",
			KEY = "Sec-WebSocket-Key".toLower(),
			KEY_MAXLEN = 192 - MAGIC.length;
		if (!client.put(msg.length)) {
			remove(client);
			return false;
		}
		if (!client.tryParse(req))
			return false;
		scope (exit)
			client.reset();
		auto key = KEY in req.headers;
		if (!key || key.length > KEY_MAXLEN) {
			try {
				size_t i;
				scope NextHandler next;
				next = () {
					if (i < handlers.length)
						handlers[i++](this, client, req, next);
				};
				next();
			} catch (Exception) {
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
		return true;
	}

	void use(ReqHandler handler)
	in (handler) {
		handlers ~= handler;
	}

private:
	void onReceive(WSClient client, in ubyte[] data) {
		import std.algorithm : swap;

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
				client.flush();
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
			client.write(pong);
			client.flush();
			return;
		case Op.PONG:
			debug (Log)
				trace("Received pong from ", client.id);
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
