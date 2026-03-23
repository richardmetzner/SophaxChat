package com.sophax.sophaxchat.network

import com.sophax.sophaxchat.protocol.WireMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.ServerSocket
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.ConcurrentHashMap

// ---------------------------------------------------------------------------
// Delegate interface (mirrors iOS TCPTransportDelegate)
// ---------------------------------------------------------------------------

interface TcpTransportListener {
    fun didConnect(peerID: String, address: String)
    fun didDisconnect(peerID: String)
    fun didReceiveMessage(message: WireMessage, fromPeerID: String)
    fun didStartListening(port: Int)
    fun didFailToSend(peerID: String, error: Exception)
}

// ---------------------------------------------------------------------------
// Wire framing: [4-byte big-endian length][JSON WireMessage]
// Matches iOS TCPTransport exactly.
// ---------------------------------------------------------------------------

private val json = Json { ignoreUnknownKeys = true }

private fun WireMessage.toFramedBytes(): ByteArray {
    val payload = json.encodeToString(this).toByteArray(Charsets.UTF_8)
    val length = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(payload.size).array()
    return length + payload
}

private fun InputStream.readWireMessage(): WireMessage? {
    val lenBuf = ByteArray(4)
    var read = 0
    while (read < 4) {
        val n = read(lenBuf, read, 4 - read)
        if (n < 0) return null
        read += n
    }
    val length = ByteBuffer.wrap(lenBuf).order(ByteOrder.BIG_ENDIAN).int
    if (length <= 0 || length > 4 * 1024 * 1024) return null  // sanity: max 4 MiB (matches iOS)

    val data = ByteArray(length)
    var totalRead = 0
    while (totalRead < length) {
        val n = read(data, totalRead, length - totalRead)
        if (n < 0) return null
        totalRead += n
    }
    return try {
        json.decodeFromString<WireMessage>(String(data, Charsets.UTF_8))
    } catch (e: Exception) { null }
}

// ---------------------------------------------------------------------------
// TcpTransport
// ---------------------------------------------------------------------------

class TcpTransport(
    private val port: Int = 25519,
    socksProxyAddress: String? = null,                // "host:port" for Tor
    var helloProvider: (() -> WireMessage)? = null,   // called on connect to get Hello
    var listener: TcpTransportListener? = null
) {
    private var socksProxyAddress: String? = socksProxyAddress

    fun setSocksProxy(host: String, port: Int) {
        socksProxyAddress = "$host:$port"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connections = ConcurrentHashMap<String, Socket>()  // peerID → socket
    private var serverSocket: ServerSocket? = null

    // -----------------------------------------------------------------------
    // Listen
    // -----------------------------------------------------------------------

    fun start() {
        scope.launch {
            try {
                val server = ServerSocket(port)
                serverSocket = server
                listener?.didStartListening(port)
                while (!server.isClosed) {
                    val socket = server.accept()
                    scope.launch { handleIncomingSocket(socket) }
                }
            } catch (e: Exception) {
                // server stopped
            }
        }
    }

    fun stop() {
        serverSocket?.close()
        connections.values.forEach { runCatching { it.close() } }
        connections.clear()
    }

    // -----------------------------------------------------------------------
    // Connect
    // -----------------------------------------------------------------------

    fun connect(address: String) {
        scope.launch {
            try {
                // Use lastIndexOf to support IPv6 addresses (e.g. [::1]:8080)
                val colonIdx = address.lastIndexOf(':')
                if (colonIdx <= 0) throw IllegalArgumentException("Invalid address: $address")
                val host    = address.substring(0, colonIdx)
                val portStr = address.substring(colonIdx + 1)
                val remotePort = portStr.toIntOrNull()?.takeIf { it in 1..65535 }
                    ?: throw IllegalArgumentException("Invalid port: $portStr")
                val socket = if (socksProxyAddress != null) {
                    val proxy0 = socksProxyAddress!!
                    val pIdx = proxy0.lastIndexOf(':')
                    if (pIdx <= 0) throw IllegalArgumentException("Invalid proxy address: $proxy0")
                    val proxyHost    = proxy0.substring(0, pIdx)
                    val proxyPortStr = proxy0.substring(pIdx + 1)
                    val proxyPort = proxyPortStr.toIntOrNull()?.takeIf { it in 1..65535 }
                        ?: throw IllegalArgumentException("Invalid proxy port: $proxyPortStr")
                    val proxy = Proxy(Proxy.Type.SOCKS, InetSocketAddress(proxyHost, proxyPort))
                    Socket(proxy).also { it.connect(InetSocketAddress(host, remotePort), 30_000) }
                } else {
                    Socket().also { it.connect(InetSocketAddress(host, remotePort), 10_000) }
                }
                handleOutgoingSocket(socket, address)
            } catch (e: Exception) {
                // connection failed — caller can retry
            }
        }
    }

    // -----------------------------------------------------------------------
    // Send
    // -----------------------------------------------------------------------

    fun send(message: WireMessage, toPeerID: String) {
        scope.launch {
            val socket = connections[toPeerID]
            if (socket == null || socket.isClosed) {
                listener?.didFailToSend(toPeerID, Exception("not connected"))
                return@launch
            }
            try {
                socket.getOutputStream().write(message.toFramedBytes())
                socket.getOutputStream().flush()
            } catch (e: Exception) {
                listener?.didFailToSend(toPeerID, e)
                disconnect(toPeerID)
            }
        }
    }

    fun isConnected(peerID: String) = connections[peerID]?.isConnected == true

    fun connectedPeerIDs(): Set<String> = connections.keys.toSet()

    fun broadcast(message: WireMessage, excluding: String? = null) {
        connections.keys.filter { it != excluding }.forEach { send(message, it) }
    }

    fun disconnect(peerID: String) {
        connections.remove(peerID)?.let { socket ->
            runCatching { socket.close() }
            listener?.didDisconnect(peerID)
        }
    }

    // -----------------------------------------------------------------------
    // Internal: handle socket (incoming or outgoing)
    // -----------------------------------------------------------------------

    private fun handleIncomingSocket(socket: Socket) = handleSocket(socket, isOutgoing = false)
    private fun handleOutgoingSocket(socket: Socket, address: String) = handleSocket(socket, isOutgoing = true, address = address)

    private fun handleSocket(socket: Socket, isOutgoing: Boolean, address: String = "") {
        var peerID: String? = null
        try {
            val input  = socket.getInputStream()
            val output = socket.getOutputStream()

            // Send our Hello first
            helloProvider?.invoke()?.let { output.write(it.toFramedBytes()); output.flush() }

            // Enforce a 10-second deadline for the peer to send their Hello.
            // Without this, an attacker holds the socket open indefinitely at zero cost.
            socket.soTimeout = 10_000
            val firstMsg = input.readWireMessage() ?: return
            socket.soTimeout = 0   // reset to blocking for the normal read loop

            peerID = firstMsg.senderID
            connections[peerID] = socket

            val remoteAddress = if (isOutgoing) address else
                "${socket.inetAddress.hostAddress}:${socket.port}"
            listener?.didConnect(peerID, remoteAddress)
            listener?.didReceiveMessage(firstMsg, peerID)

            // Read loop
            while (!socket.isClosed) {
                val msg = input.readWireMessage() ?: break
                listener?.didReceiveMessage(msg, peerID)
            }
        } catch (e: Exception) {
            // socket closed or error
        } finally {
            runCatching { socket.close() }
            peerID?.let {
                connections.remove(it)
                listener?.didDisconnect(it)
            }
        }
    }
}
