package com.sophax.sophaxchat.network

import android.content.Context
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.AdvertisingOptions
import com.google.android.gms.nearby.connection.ConnectionInfo
import com.google.android.gms.nearby.connection.ConnectionLifecycleCallback
import com.google.android.gms.nearby.connection.ConnectionResolution
import com.google.android.gms.nearby.connection.ConnectionsStatusCodes
import com.google.android.gms.nearby.connection.DiscoveredEndpointInfo
import com.google.android.gms.nearby.connection.DiscoveryOptions
import com.google.android.gms.nearby.connection.EndpointDiscoveryCallback
import com.google.android.gms.nearby.connection.Payload
import com.google.android.gms.nearby.connection.PayloadCallback
import com.google.android.gms.nearby.connection.PayloadTransferUpdate
import com.google.android.gms.nearby.connection.Strategy
import com.sophax.sophaxchat.protocol.WireMessage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.decodeFromString
import java.util.concurrent.ConcurrentHashMap

// ---------------------------------------------------------------------------
// Listener interface — mirrors iOS MeshManagerDelegate
// ---------------------------------------------------------------------------

interface NearbyManagerListener {
    fun didDiscoverPeer(endpointId: String, displayName: String)
    fun didLosePeer(endpointId: String)
    fun didConnectToPeer(endpointId: String)
    fun didDisconnectFromPeer(endpointId: String)
    fun didReceiveMessage(message: WireMessage, fromEndpointId: String)
    fun sendDidFail(endpointId: String, error: Exception)
    fun helloMessage(): WireMessage?    // called on connect to get Hello wire message
}

// ---------------------------------------------------------------------------
// NearbyManager — Android equivalent of iOS MeshManager (MultipeerConnectivity)
//
// Uses Google Nearby Connections API:
//   Strategy.P2P_CLUSTER = many-to-many mesh (matches MPC behavior)
//   Service ID: "com.sophax.sophaxchat"
// ---------------------------------------------------------------------------

class NearbyManager(private val context: Context) {

    private val client = Nearby.getConnectionsClient(context)
    private val json   = Json { ignoreUnknownKeys = true }

    var listener: NearbyManagerListener? = null

    // endpoint ID → display name (for discovery UI)
    private val discoveredEndpoints = ConcurrentHashMap<String, String>()
    // endpoint ID → connection state
    private val connectedEndpoints  = ConcurrentHashMap<String, Boolean>()

    private val SERVICE_ID = "com.sophax.sophaxchat"

    // -----------------------------------------------------------------------
    // Start (advertising + discovery)
    // -----------------------------------------------------------------------

    fun start(displayName: String) {
        startAdvertising(displayName)
        startDiscovery()
    }

    private fun startAdvertising(displayName: String) {
        val options = AdvertisingOptions.Builder()
            .setStrategy(Strategy.P2P_CLUSTER)
            .build()
        client.startAdvertising(displayName, SERVICE_ID, connectionLifecycleCallback, options)
            .addOnFailureListener { /* advertising may fail if already running */ }
    }

    private fun startDiscovery() {
        val options = DiscoveryOptions.Builder()
            .setStrategy(Strategy.P2P_CLUSTER)
            .build()
        client.startDiscovery(SERVICE_ID, endpointDiscoveryCallback, options)
            .addOnFailureListener { /* discovery may fail if already running */ }
    }

    fun stop() {
        client.stopAdvertising()
        client.stopDiscovery()
        client.stopAllEndpoints()
        connectedEndpoints.clear()
        discoveredEndpoints.clear()
    }

    // -----------------------------------------------------------------------
    // Send / Broadcast
    // -----------------------------------------------------------------------

    fun send(message: WireMessage, toEndpointId: String) {
        val bytes = json.encodeToString(message).toByteArray(Charsets.UTF_8)
        client.sendPayload(toEndpointId, Payload.fromBytes(bytes))
            .addOnFailureListener { e ->
                listener?.sendDidFail(toEndpointId, e)
            }
    }

    fun broadcast(message: WireMessage, excluding: String? = null) {
        connectedEndpoints.keys
            .filter { it != excluding }
            .forEach { send(message, it) }
    }

    fun connectedEndpointIDs(): Set<String> = connectedEndpoints.keys.toSet()
    fun isConnected(endpointId: String)     = connectedEndpoints.containsKey(endpointId)

    // -----------------------------------------------------------------------
    // Endpoint discovery
    // -----------------------------------------------------------------------

    private val endpointDiscoveryCallback = object : EndpointDiscoveryCallback() {
        override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) {
            discoveredEndpoints[endpointId] = info.endpointName
            listener?.didDiscoverPeer(endpointId, info.endpointName)
            // Auto-request connection (same as iOS auto-invite behavior)
            client.requestConnection(
                context.packageName,  // our display name for the remote side
                endpointId,
                connectionLifecycleCallback
            ).addOnFailureListener { /* already connecting */ }
        }

        override fun onEndpointLost(endpointId: String) {
            discoveredEndpoints.remove(endpointId)
            listener?.didLosePeer(endpointId)
        }
    }

    // -----------------------------------------------------------------------
    // Connection lifecycle
    // -----------------------------------------------------------------------

    private val connectionLifecycleCallback = object : ConnectionLifecycleCallback() {
        override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) {
            // Auto-accept all incoming connections (same as iOS auto-accept)
            client.acceptConnection(endpointId, payloadCallback)
        }

        override fun onConnectionResult(endpointId: String, result: ConnectionResolution) {
            if (result.status.statusCode == ConnectionsStatusCodes.STATUS_OK) {
                connectedEndpoints[endpointId] = true
                listener?.didConnectToPeer(endpointId)
                // Send Hello immediately (same as iOS behavior on MPC connect)
                listener?.helloMessage()?.let { send(it, endpointId) }
            }
        }

        override fun onDisconnected(endpointId: String) {
            connectedEndpoints.remove(endpointId)
            listener?.didDisconnectFromPeer(endpointId)
        }
    }

    // -----------------------------------------------------------------------
    // Payload (message) handling
    // -----------------------------------------------------------------------

    private val payloadCallback = object : PayloadCallback() {
        override fun onPayloadReceived(endpointId: String, payload: Payload) {
            if (payload.type != Payload.Type.BYTES) return
            val bytes = payload.asBytes() ?: return
            try {
                val message = json.decodeFromString<WireMessage>(String(bytes, Charsets.UTF_8))
                listener?.didReceiveMessage(message, endpointId)
            } catch (e: Exception) {
                // Malformed packet — silently drop
            }
        }

        override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {
            // Not needed for byte payloads
        }
    }
}
