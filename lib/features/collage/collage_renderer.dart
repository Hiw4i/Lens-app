import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

class CollageCell {
  const CollageCell(this.x, this.y, this.width, this.height);
  final double x, y, width, height;
}

/// Normalized geometry shared by screen and export. Incomplete rows fill out.
List<CollageCell> collageCells({
  required int count,
  required int columns,
  required double aspectRatio,
  required double spacing,
}) {
  if (count < 2 ||
      count > 9 ||
      columns < 1 ||
      columns > 3 ||
      !aspectRatio.isFinite ||
      aspectRatio < .5 ||
      aspectRatio > 2 ||
      !spacing.isFinite ||
      spacing < 0 ||
      spacing > .04) {
    throw ArgumentError('Invalid collage layout');
  }
  final rows = (count / columns).ceil();
  final gapY = spacing * aspectRatio;
  final height = (1 - gapY * (rows + 1)) / rows;
  return List.generate(count, (index) {
    final row = index ~/ columns;
    final rowCount = math.min(columns, count - row * columns);
    final width = (1 - spacing * (rowCount + 1)) / rowCount;
    return CollageCell(
      spacing + (index % columns) * (width + spacing),
      gapY + row * (height + gapY),
      width,
      height,
    );
  });
}

class CollageRequest {
  const CollageRequest({
    required this.images,
    required this.columns,
    required this.aspectRatio,
    required this.spacing,
    this.longEdge = 2400,
  });
  final List<Uint8List> images;
  final int columns, longEdge;
  final double aspectRatio, spacing;
}

/// Runs in a compute isolate. Decode one original at a time to bound memory.
Uint8List renderCollage(CollageRequest request) {
  final cells = collageCells(
    count: request.images.length,
    columns: request.columns,
    aspectRatio: request.aspectRatio,
    spacing: request.spacing,
  );
  if (request.longEdge < 64 || request.longEdge > 4096) {
    throw ArgumentError('Invalid export size');
  }
  final width = request.aspectRatio >= 1
      ? request.longEdge
      : (request.longEdge * request.aspectRatio).round();
  final height = request.aspectRatio >= 1
      ? (request.longEdge / request.aspectRatio).round()
      : request.longEdge;
  final output = img.Image(width: width, height: height, numChannels: 3);
  img.fill(output, color: img.ColorRgb8(255, 255, 255));
  for (var index = 0; index < cells.length; index++) {
    final decoded = img.decodeImage(request.images[index]);
    if (decoded == null) {
      throw const FormatException('A photo could not be decoded');
    }
    final image = img.bakeOrientation(decoded);
    final cell = cells[index];
    final left = (cell.x * width).round();
    final top = (cell.y * height).round();
    final cellWidth = ((cell.x + cell.width) * width).round() - left;
    final cellHeight = ((cell.y + cell.height) * height).round() - top;
    final ratio = cellWidth / cellHeight;
    final cropWidth = math
        .min(image.width, (image.height * ratio).round())
        .clamp(1, image.width);
    final cropHeight = math
        .min(image.height, (image.width / ratio).round())
        .clamp(1, image.height);
    final crop = img.copyCrop(
      image,
      x: (image.width - cropWidth) ~/ 2,
      y: (image.height - cropHeight) ~/ 2,
      width: cropWidth,
      height: cropHeight,
    );
    final resized = img.copyResize(
      crop,
      width: cellWidth,
      height: cellHeight,
      interpolation: img.Interpolation.average,
    );
    img.compositeImage(output, resized, dstX: left, dstY: top);
  }
  return img.encodeJpg(output, quality: 94);
}
