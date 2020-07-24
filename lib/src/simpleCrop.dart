part of image_crop;

const _kCropOverlayActiveOpacity = 0.3;
const _kCropOverlayInactiveOpacity = 0.7;
const _kCropHandleSize = 10.0;

enum _CropAction { none, moving, scaling }

class ImgCrop extends StatefulWidget {
  final ImageProvider image;
  final double maximumScale;
  final ImageErrorListener onImageError;
  final double chipRadius; // 裁剪半径
  final String chipShape; // 裁剪区域形状
  const ImgCrop(
      {Key key,
      this.image,
      this.maximumScale: 2.0,
      this.onImageError,
      this.chipRadius = 150,
      this.chipHeightRatio = 1.0,
      this.chipShape = 'circle'})
      : assert(image != null),
        assert(maximumScale != null),
        super(key: key);

  ImgCrop.file(File file,
      {Key key,
      double scale = 1.0,
      this.maximumScale: 2.0,
      this.onImageError,
      this.chipRadius = 150,
      this.chipHeightRatio = 1.0,
      this.chipShape = 'circle'})
      : image = FileImage(file, scale: scale),
        assert(maximumScale != null),
        super(key: key);

  ImgCrop.asset(
    String assetName, {
    Key key,
    AssetBundle bundle,
    String package,
    this.chipRadius = 150,
    this.chipHeightRatio = 1.0,
    this.maximumScale: 2.0,
    this.onImageError,
    this.chipShape = 'circle',
  })  : image = AssetImage(assetName, bundle: bundle, package: package),
        assert(maximumScale != null),
        super(key: key);

  @override
  State<StatefulWidget> createState() => ImgCropState();

  static ImgCropState of(BuildContext context) {
    return context.findAncestorStateOfType();
  }
}

class ImgCropState extends State<ImgCrop> with TickerProviderStateMixin, Drag {
  final _surfaceKey = GlobalKey();
  AnimationController _activeController;
  AnimationController _settleController;
  ImageStream _imageStream;
  ui.Image _image;
  double _scale;
  double _ratio;
  Rect _view;
  Rect _area;
  Offset _lastFocalPoint;
  _CropAction _action;
  double _startScale;
  Rect _startView;
  Tween<Rect> _viewTween;
  Tween<double> _scaleTween;
  ImageStreamListener _imageListener;

  double get scale => _area.shortestSide / _scale;

  Rect get area {
    return _view.isEmpty
        ? null
        : Rect.fromLTWH(
            _area.left * _view.width / _scale - _view.left,
            _area.top * _view.height / _scale - _view.top,
            _area.width * _view.width / _scale,
            _area.height * _view.height / _scale,
          );
  }

  bool get _isEnabled => !_view.isEmpty && _image != null;

  @override
  void initState() {
    super.initState();
    _area = Rect.zero;
    _view = Rect.zero;
    _scale = 1.0;
    _ratio = 1.0;
    _lastFocalPoint = Offset.zero;
    _action = _CropAction.none;
    _activeController = AnimationController(
      vsync: this,
      value: 0.0,
    )..addListener(() => setState(() {})); // 裁剪背景灰度控制
    _settleController = AnimationController(vsync: this)
      ..addListener(_settleAnimationChanged);
  }

  @override
  void dispose() {
    _imageStream?.removeListener(_imageListener);
    _activeController.dispose();
    _settleController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _getImage();
  }

  @override
  void didUpdateWidget(ImgCrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.image != oldWidget.image) {
      _getImage();
    }
    _activate(1.0);
  }

  Future<File> cropCompleted(File file, {int pictureQuality}) async {
    final options = await ImageCrop.getImageOptions(file: file);
    debugPrint('image width: ${options.width}, height: ${options.height}');
    final sampleFile = await ImageCrop.sampleImage(
      file: file,
      preferredWidth: (pictureQuality / scale).round(),
      preferredHeight: (pictureQuality / scale).round(),
    );

    final croppedFile = await ImageCrop.cropImage(
      file: sampleFile,
      area: area,
    );
    return croppedFile;
  }

  void _getImage({bool force: false}) {
    final oldImageStream = _imageStream;
    _imageStream = widget.image.resolve(createLocalImageConfiguration(context));
    if (_imageStream.key != oldImageStream?.key || force) {
      oldImageStream?.removeListener(_imageListener);
      _imageListener =
          ImageStreamListener(_updateImage, onError: widget.onImageError);
      _imageStream.addListener(_imageListener);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints.expand(),
      child: GestureDetector(
        key: _surfaceKey,
        behavior: HitTestBehavior.opaque,
        onScaleStart: _isEnabled ? _handleScaleStart : null,
        onScaleUpdate: _isEnabled ? _handleScaleUpdate : null,
        onScaleEnd: _isEnabled ? _handleScaleEnd : null,
        child: CustomPaint(
          painter: _CropPainter(
              image: _image,
              ratio: _ratio,
              view: _view,
              area: _area,
              scale: _scale,
              active: _activeController.value,
              chipShape: widget.chipShape),
        ),
      ),
    );
  }

  void _activate(double val) {
    _activeController.animateTo(
      val,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 250),
    );
  }

  // NOTE: 区域性缩小 总区域 - 10 * 10 区域
  Size get _boundaries {
    return _surfaceKey.currentContext.size -
        Offset(_kCropHandleSize, _kCropHandleSize);
  }
  
  // Make sure if widget.chipHeightRatio between 0 - 1.0
  double get chipHeightRatio {
    return widget.chipHeightRatio > 1.0 ? 1.0 
      : widget.chipHeightRatio < 0.0 ? 0.0
      : widget.chipHeightRatio;
  }

  void _settleAnimationChanged() {
    setState(() {
      _scale = _scaleTween.transform(_settleController
          .value); // 将0 ～ 1的动画转变过程，转换至 _scaleTween 的begin ~ end
      _view = _viewTween.transform(_settleController.value);
    });
  }

  Rect _calculateDefaultArea({
    int imageWidth,
    int imageHeight,
    double viewWidth,
    double viewHeight,
  }) {
    if (imageWidth == null || imageHeight == null) {
      return Rect.zero;
    }

    final _deviceWidth =
        MediaQuery.of(context).size.width - (2 * _kCropHandleSize);
    final _areaOffset = (_deviceWidth - (widget.chipRadius * 2));
    final _areaOffsetRadio = _areaOffset / _deviceWidth;
    final width = 1.0 - _areaOffsetRadio;

    final height =
        (imageWidth * viewWidth * width) / (imageHeight * viewHeight / chipHeightRatio);
    return Rect.fromLTWH((1.0 - width) / 2, (1.0 - height) / 2, width, height);
  }

  void _updateImage(ImageInfo imageInfo, bool synchronousCall) {
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      setState(() {
        _image = imageInfo.image;
        _scale = imageInfo.scale;

        // NOTE: conver img  _ratio value >= 0
        _ratio = max(
          _boundaries.width / _image.width,
          _boundaries.height / _image.height,
        );

        // NOTE: 计算图片显示比值，最大1.0为全部显示
        final viewWidth = _boundaries.width / (_image.width * _scale * _ratio);
        final viewHeight =
            _boundaries.height / (_image.height * _scale * _ratio);
        _area = _calculateDefaultArea(
          viewWidth: viewWidth,
          viewHeight: viewHeight,
          imageWidth: _image.width,
          imageHeight: _image.height,
        );

        // NOTE: 相对于整体图片已显示的view大小， viewWidth - 1.0 为未显示区域， / 2 算出 left的比例模型
        _view = Rect.fromLTWH(
          (viewWidth - 1.0) / 2,
          (viewHeight - 1.0) / 2,
          viewWidth,
          viewHeight,
        );
      });
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _handleScaleStart(ScaleStartDetails details) {
    _activate(1.0);
    _settleController.stop(canceled: false);
    _lastFocalPoint = details.focalPoint;
    _action = _CropAction.none;
    _startScale = _scale;
    _startView = _view;
  }

  Rect _getViewInBoundaries(double scale) {
    return Offset(
          max(
            min(
              _view.left,
              _area.left * _view.width / scale,
            ),
            _area.right * _view.width / scale - 1.0,
          ),
          max(
            min(
              _view.top,
              _area.top * _view.height / scale,
            ),
            _area.bottom * _view.height / scale - 1.0,
          ),
        ) &
        _view.size;
  }

  double get _maximumScale => widget.maximumScale;

  double get _minimumScale {
    final scaleX = _boundaries.width * _area.width / (_image.width * _ratio);
    final scaleY = _boundaries.height * _area.height / (_image.height * _ratio);
    return min(_maximumScale, max(scaleX, scaleY));
  }

  void _handleScaleEnd(ScaleEndDetails details) {
    _activate(0);

    final targetScale =
        _scale.clamp(_minimumScale, _maximumScale); //NOTE: 处理缩放边界值
    _scaleTween = Tween<double>(
      begin: _scale,
      end: targetScale,
    );

    _startView = _view;
    _viewTween = RectTween(
      begin: _view,
      end: _getViewInBoundaries(targetScale),
    );

    _settleController.value = 0.0;
    _settleController.animateTo(
      1.0,
      curve: Curves.fastOutSlowIn,
      duration: const Duration(milliseconds: 350),
    );
  }

  // 手势触发过程 判断action 类型:移动或者缩放, 跟新view 重绘image
  void _handleScaleUpdate(ScaleUpdateDetails details) {
    _action = details.rotation == 0.0 && details.scale == 1.0
        ? _CropAction.moving
        : _CropAction.scaling;

    if (_action == _CropAction.moving) {
      final delta = details.focalPoint - _lastFocalPoint; // offset相减 得出一次相对移动距离
      _lastFocalPoint = details.focalPoint;

      setState(() {
        // move只做两维方向移动
        _view = _view.translate(
          delta.dx / (_image.width * _scale * _ratio),
          delta.dy / (_image.height * _scale * _ratio),
        );
      });
    } else if (_action == _CropAction.scaling) {
      setState(() {
        _scale = _startScale * details.scale;

        // 计算已缩放的比值；
        final dx = _boundaries.width *
            (1.0 - details.scale) /
            (_image.width * _scale * _ratio);
        final dy = _boundaries.height *
            (1.0 - details.scale) /
            (_image.height * _scale * _ratio);

        _view = Rect.fromLTWH(
          _startView.left + dx / 2,
          _startView.top + dy / 2,
          _startView.width,
          _startView.height,
        );
      });
    }
  }
}

class _CropPainter extends CustomPainter {
  final ui.Image image;
  final Rect view;
  final double ratio;
  final Rect area;
  final double scale;
  final double active;
  final String chipShape;

  _CropPainter(
      {this.image,
      this.view,
      this.ratio,
      this.area,
      this.scale,
      this.active,
      this.chipShape});

  @override
  bool shouldRepaint(_CropPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.view != view ||
        oldDelegate.ratio != ratio ||
        oldDelegate.area != area ||
        oldDelegate.active != active ||
        oldDelegate.scale != scale;
  }

  currentRact(size) {
    return Rect.fromLTWH(
      _kCropHandleSize / 2,
      _kCropHandleSize / 2,
      size.width - _kCropHandleSize,
      size.height - _kCropHandleSize,
    );
  }

  Rect currentBoundaries(size) {
    var rect = currentRact(size);
    return Rect.fromLTWH(
      rect.width * area.left,
      rect.height * area.top,
      rect.width * area.width,
      rect.height * area.height,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = currentRact(size);

    canvas.save();
    canvas.translate(rect.left, rect.top);

    final paint = Paint()..isAntiAlias = false;

    if (image != null) {
      final src = Rect.fromLTWH(
        0.0,
        0.0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      final dst = Rect.fromLTWH(
        view.left * image.width * scale * ratio,
        view.top * image.height * scale * ratio,
        image.width * scale * ratio,
        image.height * scale * ratio,
      );

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0.0, 0.0, rect.width, rect.height));
      canvas.drawImageRect(image, src, dst, paint);
      canvas.restore();
    }

    paint.color = Color.fromRGBO(
        0x0,
        0x0,
        0x0,
        _kCropOverlayActiveOpacity * active +
            _kCropOverlayInactiveOpacity * (1.0 - active));
    final boundaries = currentBoundaries(size);
    final _path1 = Path()
      ..addRect(Rect.fromLTRB(0.0, 0.0, rect.width, rect.height));
    Path _path2;
    if (chipShape == 'rect') {
      _path2 = Path()..addRect(boundaries);
    } else {
      _path2 = Path()
        ..addRRect(RRect.fromLTRBR(
            boundaries.left,
            boundaries.top,
            boundaries.right,
            boundaries.bottom,
            Radius.circular(boundaries.height / 2)));
    }
    canvas.clipPath(Path.combine(
        PathOperation.difference, _path1, _path2)); //MARK: 合并路径，选择交叉选区
    canvas.drawRect(Rect.fromLTRB(0.0, 0.0, rect.width, rect.height), paint);
    paint
      ..isAntiAlias = true
      ..color = Colors.white
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    if (chipShape == 'rect') {
      canvas.drawRect(
          Rect.fromLTRB(boundaries.left - 1, boundaries.top - 1,
              boundaries.right + 1, boundaries.bottom + 1),
          paint);
    } else {
      canvas.drawRRect(
          RRect.fromLTRBR(
              boundaries.left - 1,
              boundaries.top - 1,
              boundaries.right + 1,
              boundaries.bottom + 1,
              Radius.circular(boundaries.height / 2)),
          paint);
    }

    canvas.restore();
  }
}
