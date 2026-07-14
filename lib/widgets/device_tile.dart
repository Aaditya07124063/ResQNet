import 'package:flutter/material.dart';
import '../core/constants/app_colors.dart';
import '../core/models/nearby_device.dart';

class DeviceTile extends StatelessWidget {
  final NearbyDevice device;
  final VoidCallback? onConnect;
  final bool isConnecting;

  const DeviceTile({
    super.key,
    required this.device,
    this.onConnect,
    this.isConnecting = false,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: device.isConnected
            ? AppColors.connectedGreen
            : isConnecting
                ? AppColors.primaryOrange
                : AppColors.disconnectedGrey,
        child: Icon(
          device.isConnected
              ? Icons.wifi
              : isConnecting
                  ? Icons.sync
                  : Icons.wifi_off,
          color: Colors.white,
          size: 20,
        ),
      ),
      title: Text(device.deviceName,
          style: const TextStyle(color: AppColors.textPrimary)),
      subtitle: Text(
        device.isConnected
            ? 'Connected'
            : isConnecting
                ? 'Connecting...'
                : 'Available',
        style: TextStyle(
          color: device.isConnected
              ? AppColors.connectedGreen
              : isConnecting
                  ? AppColors.primaryOrange
                  : AppColors.textSecondary,
          fontSize: 12,
        ),
      ),
      trailing: device.isConnected
          ? const Icon(Icons.check_circle, color: AppColors.connectedGreen)
          : isConnecting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: AppColors.primaryOrange),
                )
              : TextButton(
                  onPressed: onConnect,
                  style: TextButton.styleFrom(
                    backgroundColor: AppColors.accentBlue,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Connect',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                ),
    );
  }
}