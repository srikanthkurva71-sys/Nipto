import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/widgets/nipto_logo_mark.dart';

void main() {
  testWidgets('renders the supplied Nipto logo asset', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: NiptoLogoMark(size: 64))),
    );

    final image = tester.widget<Image>(find.byType(Image));
    expect(image.image, isA<AssetImage>());
    expect((image.image as AssetImage).assetName, NiptoLogoMark.assetPath);
    expect(image.width, 64);
    expect(image.height, 64);
    expect(image.fit, BoxFit.contain);
  });
}
