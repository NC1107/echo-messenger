// Translucent overlay shown while a file is being dragged over the chat panel.
import 'package:flutter/material.dart';

class DropOverlay extends StatelessWidget {
  final bool isDragOver;

  const DropOverlay({super.key, required this.isDragOver});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: isDragOver ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            color: Colors.black.withValues(alpha: 0.45),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.upload_file_outlined,
                      size: 40,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Drop file to send',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
