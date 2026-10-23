import 'package:flutter/material.dart';
import 'package:kazumi/bean/settings/network_mirror_settings.dart';
import 'package:kazumi/pages/onboarding/onboarding_step_layout.dart';

class MirrorSettingsStep extends StatelessWidget {
  const MirrorSettingsStep({super.key});

  @override
  Widget build(BuildContext context) => const OnboardingStepLayout(
    leading: OnboardingStepIcon(
      icon: Icons.public_rounded,
      shape: OnboardingIconShape.clover,
    ),
    title: '让连接更顺畅',
    subtitle: '番剧信息、评论与图片默认使用 ECH 加密握手，也可选择镜像或直连。',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NetworkMirrorSettings(margin: EdgeInsets.zero),
        OnboardingHint(text: '可在「设置 → 网络设置」中调整。'),
      ],
    ),
  );
}
