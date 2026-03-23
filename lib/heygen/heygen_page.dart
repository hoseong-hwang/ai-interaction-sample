import 'package:flutter/material.dart';

class HeygenPage extends StatelessWidget {
  const HeygenPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "HeyGen - Live Avatar",
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
        ),
      ),
      // body: const Center(child: Text("HeyGen Live Avatar")),
      body: Container(),
    );
  }
}
