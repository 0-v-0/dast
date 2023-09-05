module dast.http.settings;

import core.time;


struct ServerSettings {
    ushort port;
    bool reusePort = true;
    string serverString;
    uint maxRequestHeaderSize;
    uint threadCount;
    int connectionQueueSize = 128;
    Duration keepAliveTimeout;
    size_t bufferSize = 4 * 1024;
}