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
    try {
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
      setState(() {
        _localIp = 'Not available';
      });
    } catch (e) {
      print('Error getting local IP: $e');
      setState(() {
        _localIp = 'Error: $e';
      });
    }
  }

  String _upnpStatus = 'Not initialized';
bool _portForwarded = false;

// Обновленный метод для настройки проброса портов
Future<void> _setupPortForwarding(int port) async {
  try {
    setState(() {
      _upnpStatus = 'Initializing UPnP...';
    });

    final udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    
    setState(() {
      _upnpStatus = 'Discovering UPnP devices...';
    });

    _upnpDaemon = UpnpPortForwardDaemon('p2p_chat', (protocol, port, state) {
      print("UPnP port mapped: $protocol $port $state");
      if (protocol == 'TCP') {
        setState(() {
          _portForwarded = state;
          _forwardedPort = state ? port : 0;
          _upnpStatus = state 
              ? 'Port $port forwarded successfully' 
              : 'Failed to forward port $port';
        });
        if (state) _getPublicIp();
      }
    })
      ..tcp(port)
      ..run();
    
    setState(() {
      _upnpStatus = 'Attempting to forward port $port...';
    });

  } catch (e) {
    print('UPnP error: $e');
    setState(() {
      _upnpStatus = 'UPnP error: ${e.toString()}';
    });
  }
}

// Улучшенный метод получения публичного IP
Future<void> _getPublicIp() async {
  try {
    setState(() {
      _publicIp = 'Detecting...';
    });

    // Пробуем несколько сервисов на случай недоступности одного
    final services = [
      'https://api.ipify.org',
      'https://ident.me',
      'https://ifconfig.me/ip'
    ];

    for (var service in services) {
      try {
        final client = HttpClient();
        client.connectionTimeout = Duration(seconds: 3);
        final request = await client.getUrl(Uri.parse(service));
        final response = await request.close();
        final ip = await response.transform(utf8.decoder).join();
        
        if (ip.isNotEmpty && RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(ip)) {
          setState(() {
            _publicIp = ip;
            _upnpStatus = 'Ready for connection at $ip:$_forwardedPort';
          });
          return;
        }
      } catch (e) {
        print('Failed to get IP from $service: $e');
      }
    }

    setState(() {
      _publicIp = 'Failed to detect';
      _upnpStatus = 'Could not determine public IP';
    });
  } catch (e) {
    print('Error getting public IP: $e');
    setState(() {
      _publicIp = 'Error: ${e.toString()}';
    });
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
      _showMessage('Server started. Share your public IP: $_publicIp');
    } catch (e) {
      print('Error starting server: $e');
      _showMessage('Error starting server: $e');
    }
  }

  Future<void> _connectToServer() async {
    final ip = _remoteIpController.text;
    final port = int.tryParse(_remotePortController.text) ?? 4040;
    
    if (ip.isEmpty) return;
    
    try {
      _showMessage('Connecting to $ip:$port...');
      final socket = await Socket.connect(ip, port, timeout: Duration(seconds: 10));
      _handleConnection(socket);
      _showMessage('Connected successfully!');
    } catch (e) {
      print('Error connecting to server: $e');
      _showMessage('Connection failed: $e');
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
    _showMessage('Disconnected');
  }

  void _showMessage(String message) {
    setState(() {
      messages.add('${DateTime.now().toLocal().toString().substring(11, 19)}: $message');
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
                   
                    Text('UPnP Status: $_upnpStatus'),
                    Text('Port Forwarded: $_portForwarded'),
                    if (!_portForwarded)
                      Text('Warning: Port may not be forwarded', style: TextStyle(color: Colors.red)),
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