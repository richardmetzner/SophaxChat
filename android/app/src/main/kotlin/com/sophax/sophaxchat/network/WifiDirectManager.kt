package com.sophax.sophaxchat.network

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.NetworkInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pManager
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceInfo
import android.net.wifi.p2p.nsd.WifiP2pDnsSdServiceRequest
import android.os.Looper
import android.util.Log

/**
 * Wi-Fi Direct peer discovery for non-GMS Android devices (GrapheneOS, LineageOS, …).
 *
 * Advertises and discovers _sophaxchat._tcp peers using Wi-Fi P2P DNS-SD.
 * On peer discovery, forms a Wi-Fi Direct group and initiates a TCP connection
 * to the group owner on port 25519. All data transfer uses the existing
 * TcpTransport — no bytes are sent over Wi-Fi Direct sockets.
 *
 * Used automatically by ChatManager when Google Play Services is absent.
 * No GMS dependency — pure android.net.wifi.p2p.* SDK.
 */
@SuppressLint("MissingPermission")
class WifiDirectManager(private val context: Context) {

    companion object {
        private const val TAG          = "WifiDirectManager"
        private const val SERVICE_TYPE = "_sophaxchat._tcp"
        private const val TCP_PORT     = 25519
    }

    /** Invoked when a peer's TCP address is resolved ("host:port"). */
    var onPeerFound: ((address: String) -> Unit)? = null

    private val manager: WifiP2pManager =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as WifiP2pManager
    private val channel: WifiP2pManager.Channel =
        manager.initialize(context, Looper.getMainLooper(), null)

    private var myPeerID: String? = null

    /** Addresses we've already forwarded this session — prevents duplicate TCP connects. */
    private val connectedAddresses = mutableSetOf<String>()

    private val intentFilter = IntentFilter().apply {
        addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
    }

    @Suppress("DEPRECATION")   // NetworkInfo required for API < 29
    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action != WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION) return

            val networkInfo = intent.getParcelableExtra<NetworkInfo>(WifiP2pManager.EXTRA_NETWORK_INFO)
            if (networkInfo?.isConnected == true) {
                manager.requestConnectionInfo(channel) { info ->
                    if (!info.groupFormed) return@requestConnectionInfo
                    if (info.isGroupOwner) {
                        // We are group owner — TcpTransport.start() already listens on TCP_PORT.
                        // The non-owner will connect to us.
                        Log.d(TAG, "We are group owner; waiting for incoming TCP connection")
                    } else {
                        // Connect to group owner via TCP
                        val host = info.groupOwnerAddress?.hostAddress ?: return@requestConnectionInfo
                        val address = "$host:$TCP_PORT"
                        if (connectedAddresses.add(address)) {
                            Log.d(TAG, "Non-owner: connecting to group owner at $address")
                            onPeerFound?.invoke(address)
                        }
                    }
                }
            } else {
                connectedAddresses.clear()
            }
        }
    }

    // -------------------------------------------------------------------------
    // Public
    // -------------------------------------------------------------------------

    fun start(peerID: String) {
        myPeerID = peerID
        context.registerReceiver(receiver, intentFilter)
        advertise(peerID)
    }

    fun stop() {
        runCatching { context.unregisterReceiver(receiver) }
        manager.removeLocalServices(channel, noopListener)
        manager.removeServiceRequests(channel, noopListener)
        manager.stopPeerDiscovery(channel, noopListener)
        connectedAddresses.clear()
    }

    // -------------------------------------------------------------------------
    // Advertise + Discover
    // -------------------------------------------------------------------------

    private fun advertise(peerID: String) {
        val record = mapOf("peerid" to peerID, "port" to TCP_PORT.toString())
        val serviceInfo = WifiP2pDnsSdServiceInfo.newInstance(peerID, SERVICE_TYPE, record)
        manager.addLocalService(channel, serviceInfo, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                Log.d(TAG, "Advertised as $peerID")
                discover()
            }
            override fun onFailure(code: Int) {
                Log.w(TAG, "addLocalService failed ($code); starting discovery anyway")
                discover()
            }
        })
    }

    private fun discover() {
        // Set DNS-SD callbacks before registering the service request
        manager.setDnsSdResponseListeners(
            channel,
            { instanceName, _, device ->
                if (instanceName == myPeerID) return@setDnsSdResponseListeners
                Log.d(TAG, "Found peer: $instanceName @ ${device.deviceAddress}")
                val config = WifiP2pConfig().apply { deviceAddress = device.deviceAddress }
                manager.connect(channel, config, object : WifiP2pManager.ActionListener {
                    override fun onSuccess() { Log.d(TAG, "Connecting to $instanceName") }
                    override fun onFailure(code: Int) { Log.w(TAG, "connect() failed: $code") }
                })
            },
            { _, _, _ -> }  // TXT record map — not needed
        )

        manager.addServiceRequest(
            channel,
            WifiP2pDnsSdServiceRequest.newInstance(),
            object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    manager.discoverServices(channel, object : WifiP2pManager.ActionListener {
                        override fun onSuccess() { Log.d(TAG, "Service discovery started") }
                        override fun onFailure(code: Int) { Log.w(TAG, "discoverServices failed: $code") }
                    })
                }
                override fun onFailure(code: Int) { Log.w(TAG, "addServiceRequest failed: $code") }
            }
        )
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private val noopListener = object : WifiP2pManager.ActionListener {
        override fun onSuccess() {}
        override fun onFailure(code: Int) {}
    }
}
