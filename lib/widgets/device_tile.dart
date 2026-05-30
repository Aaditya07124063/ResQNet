import 'package:flutter/material.dart';
import '../core/models/nearby_device.dart';
import '../core/constants/app_colors.dart';

class DeviceTile extends StatelessWidget {
  final NearbyDevice device;
  final VoidCallback onConnect;
  const DeviceTile({super.key, required this.device, required this.onConnect});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor:
            device.isConnected ? AppColors.safeGreen : AppColors.lowGrey,
        child: Icon(
          device.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
          color: Colors.white,
        ),
      ),
      title: Text(device.deviceName,
          style: const TextStyle(color: AppColors.textPrimary)),
      subtitle: Text(
        device.isConnected ? 'Connected' : 'Available',
        style: TextStyle(
            color: device.isConnected
                ? AppColors.safeGreen
                : AppColors.textSecondary),
      ),
      trailing: device.isConnected
          ? null
          : ElevatedButton(
              onPressed: onConnect,
              style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.infoBlue),
              child: const Text('Connect'),
            ),
    );
  }
}
