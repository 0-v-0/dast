module dast.http.settings;

import core.time;

struct ServerSettings {
	/// The address to listen on, default is localhost
	string listen;
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
