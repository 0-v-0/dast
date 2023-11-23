module dast.wsrpc;
import core.thread,
lmpl4d,
lockfree.queue,
dast.ws.server,
std.traits;
public import dast.ws.server : PeerID, WSClient;

struct Action {
	string name;
}

struct WSRequest {
	WSClient src;
	Unpacker!() unpacker;
	Packer!() packer;
	ubyte[] buf;
	alias unpacker this;

	auto send(T...)(auto ref T data) => packer.pack(data);

	auto read(T)() => unpacker.unpack!T;

	auto read(T...)(auto ref T data) => unpacker.unpack(data);

	@property OK() {
		string err;
		return read(err) || err == "";
	}

	void reverse() nothrow {
		unpacker = Unpacker!()(packer.buf);
		packer.buf.length = 0;
	}

	bool call(alias fn, A...)(auto ref const A args) if (isCallable!fn) {
		static if (A.length)
			send(args);
		reverse();
		fn(this);
		reverse();
		return OK;
	}
}

/// get all functions with @Action
template getActions(T...) {
	import std.meta;

	alias getActions = AliasSeq!();
	static foreach (f; T)
		getActions = AliasSeq!(getActions, Filter!(isCallable, getSymbolsByUDA!(f, Action)));
}

private alias
SReq = shared WSRequest,
LFQ = LockFreeQueue!SReq;

class WSRPCServer(bool multiThread, T...) : WebSocketServer {
	public import dast.ws : Request;

	alias AllActions = getActions!T;

	static if (multiThread) {
		LFQ queue = LFQ(SReq());
		Thread[] threads;
		@property {
			size_t threadCount() const => threads.length;

			size_t threadCount(size_t n) {
				synchronized {
					auto i = threads.length;
					threads.length = n;
					for (; i < n; i++) {
						auto thread = new Thread(&mainLoop);
						thread.start();
						threads[i] = thread;
					}
					return n;
				}
			}
		}
	}

	override void onBinaryMessage(WSClient src, const(ubyte)[] msg) {
		auto req = WSRequest(src, unpacker(msg));
		static if (multiThread)
			queue.enqueue(cast(shared)req);
		else
			handleRequest(req);
	}

	static if (multiThread)
		noreturn mainLoop() {
			for (;;) {
				SReq req = void;
				while (!queue.dequeue(req))
					Thread.yield();
				handleRequest(cast()req);
			}
		}

	void handleRequest(ref WSRequest req) nothrow {
		auto unpacker = &req.unpacker;
		req.packer = packer(req.buf);
		uint id = void;
		scope (exit)
			req.buf.length = 0;
		try
			req.send(id = unpacker.unpack!uint, null);
		catch (Exception e) {
			try
				req.src.send(e.toString());
			catch (Exception) {
			}
			return;
		}
		try {
			// 调用字符串action对应的带@Action的函数
			auto action = unpacker.unpack!string;
		s:
			switch (action) {
				static foreach (f; AllActions) {
					static foreach (attr; getUDAs!(f, Action)) {
						static if (__traits(compiles, { s = attr.name; })) {
							//pragma(msg, attr.name);
			case attr.name:
						} else {
							//pragma(msg, __traits(identifier, f));
			case __traits(identifier, f):
						}
						{
							static if (arity!f == 0)
								f();
							else static if (is(Unqual!(Parameters!f[0]) == WSRequest)) {
								static assert(ParameterStorageClassTuple!f[0] & ParameterStorageClass.ref_,
									`The first parameter of Action "` ~ fullyQualifiedName!f ~ "\" must be `ref`");
								static if (arity!f == 1)
									f(req);
								else {
									Parameters!f[1 .. $] p;
									unpacker.unpackTo(p);
									f(req, p);
								}
							} else static if (arity!f == 1)
								f(unpacker.unpack!(Parameters!f));
							else {
								Parameters!f p;
								unpacker.unpackTo(p);
								f(p);
							}
						}
						break s;
					}
				}
			default:
				throw new Exception(`Unknown action "` ~ action ~ '"');
			}
		} catch (Exception e) {
			req.buf.length = 0;
			req.send(id, e.msg);
		}
		req.src.send(req.packer[]);
	}
}
