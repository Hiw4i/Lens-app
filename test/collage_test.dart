import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/collage/collage_renderer.dart';

Uint8List solid(int red, int blue) {
  final image = img.Image(width: 24, height: 40);
  img.fill(image, color: img.ColorRgb8(red, 0, blue));
  return img.encodePng(image);
}

void main() {
  test('incomplete last row fills the width without empty cells', () {
    final cells = collageCells(
      count: 5,
      columns: 3,
      aspectRatio: 1,
      spacing: .02,
    );
    expect(cells, hasLength(5));
    expect(cells[3].x, closeTo(.02, .0001));
    expect(cells[4].x + cells[4].width, closeTo(.98, .0001));
    for (final cell in cells) {
      expect(cell.width, greaterThan(0));
      expect(cell.height, greaterThan(0));
      expect(cell.y + cell.height, lessThanOrEqualTo(1));
    }
  });
  test('render preserves selected order, aspect and white spacing', () {
    final bytes = renderCollage(
      CollageRequest(
        images: [solid(255, 0), solid(0, 255)],
        columns: 2,
        aspectRatio: 2,
        spacing: .04,
        longEdge: 200,
      ),
    );
    final image = img.decodeJpg(bytes)!;
    expect(image.width, 200);
    expect(image.height, 100);
    expect(image.getPixel(45, 50).r, greaterThan(220));
    expect(image.getPixel(155, 50).b, greaterThan(220));
    expect(image.getPixel(100, 50).g, greaterThan(220));
  });
  test('corrupt image fails rather than exporting a missing photo', () {
    expect(
      () => renderCollage(
        CollageRequest(
          images: [solid(255, 0), Uint8List(8)],
          columns: 2,
          aspectRatio: 1,
          spacing: 0,
          longEdge: 100,
        ),
      ),
      throwsFormatException,
    );
  });
}
