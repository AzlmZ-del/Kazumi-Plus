import 'package:flutter/material.dart';
import 'package:kazumi/bean/widget/error_widget.dart';

class MediaErrorWidget extends StatelessWidget {
  const MediaErrorWidget({
    super.key,
    required this.title,
    required this.errMsg,
    required this.icon,
  });

  final String title;
  final String errMsg;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 媒体区域固定深色，不跟随 App 主题。
    return Theme(
      data: theme.copyWith(
        colorScheme: ColorScheme.fromSeed(
          seedColor: theme.colorScheme.primary,
          brightness: Brightness.dark,
        ),
      ),
      child: GeneralErrorWidget(
        title: title,
        errMsg: errMsg,
        icon: icon,
        compact: true,
      ),
    );
  }
}
