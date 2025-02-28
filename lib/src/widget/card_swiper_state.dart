part of 'card_swiper.dart';

class _CardSwiperState<T extends Widget> extends State<CardSwiper>
    with SingleTickerProviderStateMixin {
  late CardAnimation _cardAnimation;
  late AnimationController _animationController;

  SwipeType _swipeType = SwipeType.none;
  CardSwiperDirection _detectedDirection = CardSwiperDirection.none;
  CardSwiperDirection _detectedHorizontalDirection = CardSwiperDirection.none;
  CardSwiperDirection _detectedVerticalDirection = CardSwiperDirection.none;
  bool _tappedOnTop = false;

  final _undoableIndex = Undoable<int?>(null);
  final Queue<CardSwiperDirection> _directionHistory = Queue();

  int? get _currentIndex => _undoableIndex.state;

  int? get _nextIndex => getValidIndexOffset(1);

  bool get _canSwipe => _currentIndex != null && !widget.isDisabled;

  StreamSubscription<ControllerEvent>? controllerSubscription;

  // New state variables for interactive back swipe:
  bool _isBackSwipe = false;
  double _backSwipeDragDistance = 0.0;
  double _backSwipeProgress = 0.0;
  int? _originalIndex; // to store the card before starting a back swipe

  final slowBackSwipeFactor = 0.25;

  @override
  void initState() {
    super.initState();

    _undoableIndex.state = widget.initialIndex;

    controllerSubscription =
        widget.controller?.events.listen(_controllerListener);

    _animationController = AnimationController(
      duration: widget.duration,
      vsync: this,
    )
      ..addListener(_animationListener)
      ..addStatusListener(_animationStatusListener);

    _cardAnimation = CardAnimation(
      animationController: _animationController,
      maxAngle: widget.maxAngle,
      initialScale: widget.scale,
      allowedSwipeDirection: widget.allowedSwipeDirection,
      initialOffset: widget.backCardOffset,
      onSwipeDirectionChanged: onSwipeDirectionChanged,
    );
  }

  void onSwipeDirectionChanged(CardSwiperDirection direction) {
    switch (direction) {
      case CardSwiperDirection.none:
        _detectedVerticalDirection = direction;
        _detectedHorizontalDirection = direction;
      case CardSwiperDirection.right:
      case CardSwiperDirection.left:
        _detectedHorizontalDirection = direction;
      case CardSwiperDirection.top:
      case CardSwiperDirection.bottom:
        _detectedVerticalDirection = direction;
    }

    widget.onSwipeDirectionChange
        ?.call(_detectedHorizontalDirection, _detectedVerticalDirection);
  }

  @override
  void dispose() {
    _animationController.dispose();
    controllerSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Padding(
          padding: widget.padding,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              return Stack(
                clipBehavior: Clip.none,
                fit: StackFit.expand,
                children: List.generate(numberOfCardsOnScreen(), (index) {
                  if (index == 0) return _frontItem(constraints);
                  return _backItem(constraints, index);
                }).reversed.toList(),
              );
            },
          ),
        );
      },
    );
  }

  Widget _frontItem(BoxConstraints constraints) {
    return Positioned(
      left: _cardAnimation.left,
      top: _cardAnimation.top,
      child: GestureDetector(
        child: Transform.rotate(
          angle: _cardAnimation.angle,
          child: ConstrainedBox(
            constraints: constraints,
            child: widget.cardBuilder(
              context,
              _currentIndex!,
              (100 * _cardAnimation.left / widget.threshold).ceil(),
              (100 * _cardAnimation.top / widget.threshold).ceil(),
            ),
          ),
        ),
        onTap: () async {
          if (widget.isDisabled) {
            await widget.onTapDisabled?.call();
          }
        },
        onPanStart: (tapInfo) {
          if (!widget.isDisabled) {
            final renderBox = context.findRenderObject()! as RenderBox;
            final position = renderBox.globalToLocal(tapInfo.globalPosition);
            if (position.dy < renderBox.size.height / 2) _tappedOnTop = true;
          }
        },
        onPanUpdate: (tapInfo) {
          if (!widget.isDisabled) {
            // If an allowed back swipe direction is provided,
            // compute the dot product of the delta with that direction.
            if (widget.allowedSwipeBackDirection != null) {
              final angleRad = (widget.allowedSwipeBackDirection!.angle - 90) *
                  math.pi /
                  180;
              final backDir = Offset(math.cos(angleRad), math.sin(angleRad));
              final deltaProjection =
                  tapInfo.delta.dx * backDir.dx + tapInfo.delta.dy * backDir.dy;

              // Only trigger back swipe if the card is nearly centered.
              final atCenter = _cardAnimation.left.abs() < 5.0 &&
                  _cardAnimation.top.abs() < 5.0;

              // If not already in back swipe mode and movement is along the back direction:
              if (!_isBackSwipe && atCenter && deltaProjection > 0) {
                _startBackSwipe();
              }
              // If in back swipe mode, update progress.
              if (_isBackSwipe) {
                _backSwipeDragDistance += deltaProjection * slowBackSwipeFactor;
                double progress =
                    (_backSwipeDragDistance / widget.threshold).clamp(0.0, 1.0);
                _updateBackSwipeProgress(progress);
                return;
              }
            }
            // Otherwise, perform normal swipe update.
            setState(
              () => _cardAnimation.update(
                tapInfo.delta.dx,
                tapInfo.delta.dy,
                _tappedOnTop,
              ),
            );
          }
        },
        onPanEnd: (tapInfo) {
          final velocity = tapInfo.velocity.pixelsPerSecond.distance;
          if (_isBackSwipe) {
            if (_backSwipeProgress >= 0.3 || velocity > 1000) {
              // Complete the back swipe from the current state to centered.
              _swipeType = SwipeType.backSwipe;
              _cardAnimation.animateBackSwipeComplete(context);
            } else {
              // Cancel: animate from current state back to the opposite off–screen position.
              _swipeType = SwipeType.backSwipeCancel;
              final size = MediaQuery.of(context).size;
              final angleRad = (widget.allowedSwipeBackDirection!.angle - 90) *
                  math.pi /
                  180;
              final magnitude = size.width;
              // Calculate the off–screen target from the opposite direction.
              final targetLeft = -magnitude * math.cos(angleRad);
              final targetTop = -magnitude * math.sin(angleRad);
              _cardAnimation.animateUndoCancel(
                context,
                targetLeft,
                targetTop,
                1.0, // target scale (off-screen)
                widget.backCardOffset,
              );
            }
            _isBackSwipe = false;
            _backSwipeDragDistance = 0.0;
            _backSwipeProgress = 0.0;
            return;
          }
          if (_canSwipe) {
            _tappedOnTop = false;
            _onEndAnimation();
          }
        },
      ),
    );
  }

  void _startBackSwipe() {
    if (_currentIndex == null) return;
    // Determine the previous card index (same logic as before)
    int prevIndex;
    if (widget.isLoop) {
      prevIndex = (_currentIndex! - 1 + widget.cardsCount) % widget.cardsCount;
    } else {
      if (_currentIndex! == 0) return; // no previous card available
      prevIndex = _currentIndex! - 1;
    }
    _swipeType = SwipeType.backSwipe;
    _originalIndex = _currentIndex; // save original index in case of cancel
    _undoableIndex.state = prevIndex; // update current index to previous card

    final size = MediaQuery.of(context).size;
    // Compute the starting position from the opposite direction:
    final angleRad =
        (widget.allowedSwipeBackDirection!.angle - 90) * math.pi / 180;
    final magnitude = size.width;
    // Multiply by -1 to get the opposite side.
    final startX = -magnitude * math.cos(angleRad);
    final startY = -magnitude * math.sin(angleRad);
    setState(() {
      _cardAnimation.left = startX;
      _cardAnimation.top = startY;
      _cardAnimation.scale = 1.0;
      _cardAnimation.difference = widget.backCardOffset;
      _isBackSwipe = true;
      _backSwipeDragDistance = 0.0;
      _backSwipeProgress = 0.0;
    });
  }

  void _updateBackSwipeProgress(double progress) {
    final size = MediaQuery.of(context).size;
    final angleRad =
        (widget.allowedSwipeBackDirection!.angle - 90) * math.pi / 180;
    final magnitude = size.width;
    // Use negative starting values for the opposite direction.
    final startX = -magnitude * math.cos(angleRad);
    final startY = -magnitude * math.sin(angleRad);

    setState(() {
      _cardAnimation.left = startX * (1 - progress);
      _cardAnimation.top = startY * (1 - progress);
      // Interpolate scale from 1.0 (off-screen) to widget.scale (final)
      _cardAnimation.scale = 1.0 + (widget.scale - 1.0) * progress;
      // Interpolate difference from the starting backCardOffset to zero.
      _cardAnimation.difference =
          Offset.lerp(widget.backCardOffset, Offset.zero, progress) ??
              Offset.zero;
      _backSwipeProgress = progress;
    });
  }

  Widget _backItem(BoxConstraints constraints, int index) {
    return Positioned(
      top: (widget.backCardOffset.dy * index) - _cardAnimation.difference.dy,
      left: (widget.backCardOffset.dx * index) - _cardAnimation.difference.dx,
      child: Transform.scale(
        scale: _cardAnimation.scale - ((1 - widget.scale) * (index - 1)),
        child: ConstrainedBox(
          constraints: constraints,
          child: widget.cardBuilder(context, getValidIndexOffset(index)!, 0, 0),
        ),
      ),
    );
  }

  void _controllerListener(ControllerEvent event) {
    return switch (event) {
      ControllerSwipeEvent(:final direction) => _swipe(direction),
      ControllerUndoEvent() => _undo(),
      ControllerMoveEvent(:final index) => _moveTo(index),
    };
  }

  void _animationListener() {
    if (_animationController.status == AnimationStatus.forward) {
      setState(_cardAnimation.sync);
    }
  }

  Future<void> _animationStatusListener(AnimationStatus status) async {
    if (status == AnimationStatus.completed) {
      switch (_swipeType) {
        case SwipeType.swipe:
          await _handleCompleteSwipe();
          break;
        case SwipeType.undo:
          // Undo callback already handled in _undo()
          break;
        case SwipeType.backSwipe:
          final oldIndex =
              _originalIndex ?? _undoableIndex.previousState ?? _currentIndex!;
          final newIndex = _currentIndex!;
          final direction = widget.allowedSwipeBackDirection!;
          widget.onSwipe?.call(oldIndex, newIndex, direction);
          break;
        case SwipeType.backSwipeCancel:
          // Revert back to the original card.
          _undoableIndex.state = _originalIndex;
          break;
        default:
          break;
      }
      _reset();
    }
  }

  Future<void> _handleCompleteSwipe() async {
    final isLastCard = _currentIndex! == widget.cardsCount - 1;
    final shouldCancelSwipe = await widget.onSwipe
            ?.call(_currentIndex!, _nextIndex, _detectedDirection) ==
        false;

    if (shouldCancelSwipe) {
      return;
    }

    _undoableIndex.state = _nextIndex;
    _directionHistory.add(_detectedDirection);

    if (isLastCard) {
      widget.onEnd?.call();
    }
  }

  void _reset() {
    onSwipeDirectionChanged(CardSwiperDirection.none);
    _detectedDirection = CardSwiperDirection.none;
    _originalIndex = null;
    _isBackSwipe = false;
    setState(() {
      _animationController.reset();
      _cardAnimation.reset();
      _swipeType = SwipeType.none;
    });
  }

  void _onEndAnimation() {
    final direction = _getEndAnimationDirection();
    final isValidDirection = _isValidDirection(direction);

    if (isValidDirection) {
      _swipe(direction);
    } else {
      _goBack();
    }
  }

  CardSwiperDirection _getEndAnimationDirection() {
    if (_cardAnimation.left.abs() > widget.threshold) {
      return _cardAnimation.left.isNegative
          ? CardSwiperDirection.left
          : CardSwiperDirection.right;
    }
    if (_cardAnimation.top.abs() > widget.threshold) {
      return _cardAnimation.top.isNegative
          ? CardSwiperDirection.top
          : CardSwiperDirection.bottom;
    }
    return CardSwiperDirection.none;
  }

  bool _isValidDirection(CardSwiperDirection direction) {
    return switch (direction) {
      CardSwiperDirection.left => widget.allowedSwipeDirection.left,
      CardSwiperDirection.right => widget.allowedSwipeDirection.right,
      CardSwiperDirection.top => widget.allowedSwipeDirection.up,
      CardSwiperDirection.bottom => widget.allowedSwipeDirection.down,
      _ => false
    };
  }

  void _swipe(CardSwiperDirection direction) {
    if (_currentIndex == null) return;
    _swipeType = SwipeType.swipe;
    _detectedDirection = direction;
    _cardAnimation.animate(context, direction);
  }

  void _goBack() {
    _swipeType = SwipeType.back;
    _cardAnimation.animateBack(context);
  }

  void _undo() {
    if (_directionHistory.isEmpty) return;
    if (_undoableIndex.previousState == null) return;

    final direction = _directionHistory.last;
    final shouldCancelUndo = widget.onUndo?.call(
          _currentIndex,
          _undoableIndex.previousState!,
          direction,
        ) ==
        false;

    if (shouldCancelUndo) {
      return;
    }

    _undoableIndex.undo();
    _directionHistory.removeLast();
    _swipeType = SwipeType.undo;
    _cardAnimation.animateUndo(context, direction);
  }

  void _moveTo(int index) {
    if (index == _currentIndex) return;
    if (index < 0 || index >= widget.cardsCount) return;

    setState(() {
      _undoableIndex.state = index;
    });
  }

  int numberOfCardsOnScreen() {
    if (widget.isLoop) {
      return widget.numberOfCardsDisplayed;
    }
    if (_currentIndex == null) {
      return 0;
    }

    return math.min(
      widget.numberOfCardsDisplayed,
      widget.cardsCount - _currentIndex!,
    );
  }

  int? getValidIndexOffset(int offset) {
    if (_currentIndex == null) {
      return null;
    }

    final index = _currentIndex! + offset;
    if (!widget.isLoop && !index.isBetween(0, widget.cardsCount - 1)) {
      return null;
    }
    return index % widget.cardsCount;
  }
}
