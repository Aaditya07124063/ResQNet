import 'package:flutter/material.dart';
import '../models/emergency_message.dart';
import '../constants/app_colors.dart';

Color priorityColor(PriorityLevel p) {
  switch (p) {
    case PriorityLevel.critical: return AppColors.criticalRed;
    case PriorityLevel.high: return AppColors.highOrange;
    case PriorityLevel.medium: return AppColors.mediumYellow;
    case PriorityLevel.low: return AppColors.lowGrey;
  }
}

String priorityLabel(PriorityLevel p) {
  switch (p) {
    case PriorityLevel.critical: return 'CRITICAL';
    case PriorityLevel.high: return 'HIGH';
    case PriorityLevel.medium: return 'MEDIUM';
    case PriorityLevel.low: return 'LOW';
  }
}
