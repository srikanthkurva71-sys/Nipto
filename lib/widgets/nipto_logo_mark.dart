import 'package:flutter/material.dart';

import '../theme/nipto_theme.dart';

class NiptoLogoMark extends StatelessWidget {
  const NiptoLogoMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: NiptoBrand.markGradient,
              borderRadius: BorderRadius.circular(size * 0.27),
              boxShadow: [
                BoxShadow(
                  color: NiptoColors.violet.withValues(alpha: 0.18),
                  blurRadius: size * 0.28,
                  offset: Offset(0, size * 0.12),
                ),
              ],
            ),
          ),
          Center(
            child: Text(
              'N',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.73,
                height: 1,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: -size * 0.09,
              ),
            ),
          ),
          Positioned(
            right: -size * 0.12,
            top: -size * 0.10,
            child: Container(
              width: size * 0.43,
              height: size * 0.36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF648D), NiptoColors.brandMagenta],
                ),
                borderRadius: BorderRadius.circular(size * 0.15),
                border: Border.all(color: Colors.white, width: size * 0.025),
              ),
              child: Icon(
                Icons.groups_rounded,
                color: Colors.white,
                size: size * 0.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
