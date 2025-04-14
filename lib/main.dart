import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:upnp_port_forward/init.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'P2P Chat with UPnP',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSwatch(primarySwatch: Colors.blue),
      ),
      home: ChatScreen(),
    );
  }
}

class ChatScreen extends StatefulWidget {
  @override
  _ChatScreenState createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _portController = TextEditingController(text: '4040');
  final TextEditingController _remoteIpController = TextEditingController();
  final TextEditingController _remotePortController = TextEditingController(text: '4040');
  
  List<String> messages = [];
  ServerSocket? _server;
  Socket? _clientSocket;
  bool _isConnected = false;
  bool _isHosting = false;
  String _publicIp = '';
  String _localIp = '';
  int _forwardedPort = 0;
  UpnpPortForwardDaemon? _upnpDaemon;

  @override
  void initState() {
    super.initState();
    _getLocalIp();
  }

  @override
  void dispose() {
    _server?.close();
    _clientSocket?.close();
    _removePortForwarding();
    super.dispose();
  }

  void _getLocalIp() async {
    for (var interface in await NetworkInterface.list()) {
      for (var addr in interface.addresses) {
        if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
          setState(() {
            _localIp = addr.address;
          });
          return;
        }
      }
    }
  }

  Future<void> _setupPortForwarding(int port) async {
    try {
      final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _upnpDaemon = UpnpPortForwardDaemon('p2p_chat', (protocol, port, state) {
        print("UPnP port mapped: $protocol $port $state");
        if (state) {
          setState(() {
            _forwardedPort = port;
            _publicIp = _upnpDaemon?.externalIP ?? 'Unknown';
          });
        }
      })
        ..udp(port)
        ..tcp(port)
        ..run();
      
      print("Trying to map port $port");
    } catch (e) {
      print('UPnP error: $e');
    }
  }

  Future<void> _removePortForwarding() async {
    _upnpDaemon = null;
    setState(() {
      _forwardedPort = 0;
      _publicIp = '';
    });
  }

  Future<void> _startServer() async {
    final port = int.tryParse(_portController.text) ?? 4040;
    
    try {
      await _setupPortForwarding(port);
      
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port);
      setState(() {
        _isHosting = true;
      });
      
      _server!.listen((Socket socket) {
        _handleConnection(socket);
      });
      
      print('Server started on port $port');
    } catch (e) {
      print('Error starting server: $e');
    }
  }

  Future<void> _connectToServer() async {
    final ip = _remoteIpController.text;
    final port = int.tryParse(_remotePortController.text) ?? 4040;
    
    if (ip.isEmpty) return;
    
    try {
      final socket = await Socket.connect(ip, port, timeout: Duration(seconds: 10));
      _handleConnection(socket);
      print('Connected to $ip:$port');
    } catch (e) {
      print('Error connecting to server: $e');
      _showMessage('Connection error: $e');
    }
  }

  void _handleConnection(Socket socket) {
    setState(() {
      _clientSocket = socket;
      _isConnected = true;
    });
    
    socket.listen(
      (data) {
        final message = utf8.decode(data).trim();
        _showMessage('Remote: $message');
      },
      onError: (error) {
        print('Socket error: $error');
        _disconnect();
      },
      onDone: () {
        print('Socket closed');
        _disconnect();
      },
    );
  }

  void _sendMessage() {
    final message = _messageController.text;
    if (message.isEmpty || _clientSocket == null) return;
    
    try {
      _clientSocket!.write('$message\n');
      _showMessage('You: $message');
      _messageController.clear();
    } catch (e) {
      print('Error sending message: $e');
      _disconnect();
    }
  }

  void _disconnect() {
    _clientSocket?.close();
    _server?.close();
    setState(() {
      _clientSocket = null;
      _server = null;
      _isConnected = false;
      _isHosting = false;
    });
    _removePortForwarding();
  }

  void _showMessage(String message) {
    setState(() {
      messages.add(message);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('P2P Chat'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            // Connection Info
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Local IP: $_localIp'),
                    Text('Public IP: $_publicIp'),
                    if (_forwardedPort != 0) Text('Forwarded Port: $_forwardedPort'),
                  ],
                ),
              ),
            ),
            SizedBox(height: 16),
            
            // Connection Controls
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _portController,
                    decoration: InputDecoration(
                      labelText: 'Port',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isHosting ? null : _startServer,
                  child: Text('Host'),
                ),
              ],
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _remoteIpController,
                    decoration: InputDecoration(
                      labelText: 'Remote IP',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _remotePortController,
                    decoration: InputDecoration(
                      labelText: 'Remote Port',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ),
                SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _isConnected ? null : _connectToServer,
                  child: Text('Connect'),
                ),
              ],
            ),
            SizedBox(height: 16),
            
            // Chat Messages
            Expanded(
              child: Card(
                child: ListView.builder(
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(messages[index]),
                    );
                  },
                ),
              ),
            ),
            
            // Message Input
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    decoration: InputDecoration(
                      labelText: 'Message',
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isConnected,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                SizedBox(width: 8),
                IconButton(
                  icon: Icon(Icons.send),
                  onPressed: _isConnected ? _sendMessage : null,
                ),
              ],
            ),
            
            // Disconnect Button
            if (_isConnected)
              ElevatedButton(
                onPressed: _disconnect,
                child: Text('Disconnect'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

extension on UpnpPortForwardDaemon? {
  get externalIP => null;
}