package com.sophax.sophaxchat.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log

/**
 * mDNS/NSD discovery — enables automatic Android ↔ iOS peer discovery
 * on the same WiFi network, without any central server.
 *
 * Both platforms advertise "_sophaxchat._tcp" on port 25519.
 * On discovery, the resolved address is handed to [listener] which
 * initiates a TCP connection. The normal Hello / X3DH handshake takes
 * over from there — this class is transport-only, no crypto.
 */
class LanDiscovery(private val context: Context) {

    companion object {
        private const val TAG          = "LanDiscovery"
        private const val SERVICE_TYPE = "_sophaxchat._tcp"
        private const val PORT         = 25519
    }

    var listener: LanDiscoveryListener? = null

    private val nsd: NsdManager =
        context.getSystemService(Context.NSD_SERVICE) as NsdManager

    private var myServiceName: String? = null

    /** Names of peers we have already forwarded to the listener this session. */
    private val resolved = mutableSetOf<String>()

    private var registrationListener: NsdManager.RegistrationListener? = null
    private var discoveryListener: NsdManager.DiscoveryListener?       = null

    // -------------------------------------------------------------------------
    // Public
    // -------------------------------------------------------------------------

    fun start(peerID: String) {
        myServiceName = peerID

        // Advertise ourselves so iOS (and other Android) peers can find us
        val info = NsdServiceInfo().apply {
            serviceName = peerID
            serviceType = SERVICE_TYPE
            port        = PORT
        }
        val regListener = makeRegistrationListener()
        registrationListener = regListener
        nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, regListener)

        // Browse for others
        val discListener = makeDiscoveryListener()
        discoveryListener = discListener
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discListener)
    }

    fun stop() {
        runCatching { registrationListener?.let { nsd.unregisterService(it) } }
        runCatching { discoveryListener?.let    { nsd.stopServiceDiscovery(it) } }
        registrationListener = null
        discoveryListener    = null
        resolved.clear()
    }

    // -------------------------------------------------------------------------
    // Listeners
    // -------------------------------------------------------------------------

    private fun makeRegistrationListener() = object : NsdManager.RegistrationListener {
        override fun onServiceRegistered(info: NsdServiceInfo) {
            // NSD may append a suffix to avoid conflicts; update our name
            myServiceName = info.serviceName
            Log.d(TAG, "Advertised as ${info.serviceName}")
        }
        override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
            Log.w(TAG, "Registration failed: $code")
        }
        override fun onServiceUnregistered(info: NsdServiceInfo) {}
        override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
    }

    private fun makeDiscoveryListener() = object : NsdManager.DiscoveryListener {
        override fun onDiscoveryStarted(type: String) {
            Log.d(TAG, "Discovery started for $type")
        }
        override fun onServiceFound(info: NsdServiceInfo) {
            when {
                info.serviceType != SERVICE_TYPE          -> return  // wrong type
                info.serviceName == myServiceName         -> return  // self
                resolved.contains(info.serviceName)       -> return  // already connected
            }
            // NsdManager requires a *new* ResolveListener per call
            nsd.resolveService(info, makeResolveListener())
        }
        override fun onServiceLost(info: NsdServiceInfo) {
            resolved.remove(info.serviceName)
        }
        override fun onDiscoveryStopped(type: String) {}
        override fun onStartDiscoveryFailed(type: String, code: Int) {
            Log.w(TAG, "Discovery failed to start: $code")
        }
        override fun onStopDiscoveryFailed(type: String, code: Int) {}
    }

    private fun makeResolveListener() = object : NsdManager.ResolveListener {
        override fun onServiceResolved(info: NsdServiceInfo) {
            val host = info.host?.hostAddress ?: return
            resolved.add(info.serviceName)
            Log.d(TAG, "Resolved peer at $host:${info.port}")
            listener?.onLanPeerFound("$host:${info.port}")
        }
        override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
            Log.w(TAG, "Resolve failed for ${info.serviceName}: $code")
        }
    }
}

interface LanDiscoveryListener {
    /** Called when a peer's TCP address has been resolved ("host:port"). */
    fun onLanPeerFound(address: String)
}
