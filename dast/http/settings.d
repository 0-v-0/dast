module dast.http.settings;

import core.time;


struct ServerSettings {
	/// The port to listen on
	ushort port;
	/// Enable address reuse in listenTCP()
	bool reuseAddress = true;
	/// Enable port reuse in listenTCP()
	bool reusePort = true;
	//string serverString;
	uint maxRequestHeaderSize;
	uint threadCount;
	uint maxConnections;
	int connectionQueueSize = 128;
	Duration keepAliveTimeout;
	uint bufferSize = 4 * 1024;
}