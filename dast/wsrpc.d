module dast.wsrpc;
// dfmt off
import
	core.thread,
	lmpl4d,
	lockfree.queue,
	dast.ws.server;
// dfmt on
import std.traits : isCallable;
public import dast.ws.server : PeerID, WSClient;

struct Action {
	string name;
}

struct WSRequest {
	WSClient src;
	Unpacker!() unpacker;
	Packer!() packer;
	alias unpacker this;

	auto send(T...)(T data) => packer.pack(data);

	auto read(T)() => unpacker.unpack!T;

	auto read(T...)(auto ref T data) => unpacker.unpack(data);

	@property auto OK() {
		string err;
		return read(err) || err == "";
	}

	void reverse() nothrow {
		unpacker = Unpacker!()(packer.buf);
		packer.buf.length = 0;
	}

	bool call(alias fn, Args...)(auto ref const Args args) if (isCallable!fn) {
		static if (Args.length)
			send(args);
		reverse();
		fn(this);
		reverse();
		return OK;
	}
}

/// get all functions with @Action
template getActions(T...) {
	import std.meta, std.traits;

	static if (T.length > 1)
		alias getActions = AliasSeq!(getActions!(T[0]), getActions!(T[1 .. $]));
	else
		alias getActions = Filter!(isCallable, getSymbolsByUDA!(T, Action));
}

package alias
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
	protected ubyte[] buf;

	override void onBinaryMessage(WSClient src, const(ubyte)[] msg) {
		static if (multiThread)
			queue.enqueue(SReq(cast(shared)src, cast(shared)Unpacker!()(msg)));
		else {
			auto req = WSRequest(src, Unpacker!()(msg));
			handleRequest(req);
		}
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
		req.packer = packer(buf);
		uint id = void;
		scope (exit)
			buf.length = 0;
		try
			req.send(id = unpacker.unpack!uint);
		catch (Exception e) {
			try
				req.src.send(e.toString);
			catch (Exception) {
			}
			return;
		}
		try {
			// 调用字符串action对应的带@Action的函数
			auto action = unpacker.unpack!string;
		s:
			switch (action) {
				static foreach (i, f; AllActions) {
					static foreach (attr; getUDAs!(f, Action)) {
						static if (__traits(compiles, { s = attr.name; })) {
							//pragma(msg, attr.name);
			case attr.name:
						} else {
							//pragma(msg, __traits(identifier, f));
			case __traits(identifier, f):
						}
						static if (arity!f == 0)
							f();
						else {
							static if (is(Unqual!(Parameters!f[0]) == WSRequest)) {
								static assert(ParameterStorageClassTuple!f[0] & ParameterStorageClass.ref_,
								"The first parameter of Action \"" ~ fullyQualifiedName!f ~ "\" must be `ref`");
								static if (arity!f == 1)
									f(req);
								else
									mixin("Parameters!f[1..$] p", i, ";",
										"unpacker.unpack(p", i, ");",
										"f(req, p", i, ");");
							} else {
								static if (arity!f == 1)
									f(unpacker.unpack!(Parameters!f));
								else
									mixin("Parameters!f p", i, ";",
										"unpacker.unpack(p", i, ");",
										"f(p", i, ");");
							}
						}
						break s;
					}
				}
			default:
				throw new Exception("Unknown action \"" ~ action ~ "\"");
			}
		} catch (Exception e) {
			buf.length = 0;
			req.send(id, e.msg);
		}
		req.src.send(req.packer[]);
	}
}
