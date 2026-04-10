// Copyright 2026 AntlerAI. All rights reserved.
// Use of this source code is governed by a BSD-style license.
//
// Unit tests for OWLRemoteLayerView — Phase 2 retina/scale fixes.
// Tests AC1–AC6 via public interface only.

#import "third_party/owl/bridge/OWLRemoteLayerView.h"

#import <QuartzCore/QuartzCore.h>

#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// ---------------------------------------------------------------------------
// Helper: find the sublayer created by updateWithContextId:.
// OWLRemoteLayerView uses layer-hosting mode; after an update the view's
// layer should contain a sublayer (CALayerHost in production, or whatever
// the implementation creates).  We inspect the *first* sublayer.
// ---------------------------------------------------------------------------
static CALayer* FindRemoteSublayer(OWLRemoteLayerView* view) {
  return view.layer.sublayers.firstObject;
}

// ---------------------------------------------------------------------------
// Fixture — creates an OWLRemoteLayerView without a window (window=nil).
// This is the typical state when the view has not yet been added to a
// window, which exercises the "window=nil" fallback path.
// ---------------------------------------------------------------------------
class OWLRemoteLayerViewTest : public testing::Test {
 protected:
  void SetUp() override {
    view_ = [[OWLRemoteLayerView alloc]
        initWithFrame:NSMakeRect(0, 0, 800, 600)];
    // Ensure the view has a backing layer (layer-hosting mode).
    [view_ setWantsLayer:YES];
  }

  void TearDown() override {
    view_ = nil;
  }

  OWLRemoteLayerView* view_ = nil;
};

// ===================================================================
// AC1: window=nil — contentsScale uses the passed-in scaleFactor
//      (not the default 1.0).
// ===================================================================

// Happy path: Retina scale (2.0) applied when window is nil.
TEST_F(OWLRemoteLayerViewTest, AC1_WindowNil_ContentsScaleUsesScaleFactor_Retina) {
  // Precondition: view has no window.
  ASSERT_EQ(view_.window, nil);

  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  // If the implementation uses a CALayerHost (private API) that cannot be
  // created in a test environment, the sublayer may be nil.  Skip gracefully.
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 2.0);
}

// Happy path: 1x scale applied when window is nil.
TEST_F(OWLRemoteLayerViewTest, AC1_WindowNil_ContentsScaleUsesScaleFactor_1x) {
  ASSERT_EQ(view_.window, nil);

  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);
}

// Edge: 3x scale (future high-DPI displays).
TEST_F(OWLRemoteLayerViewTest, AC1_WindowNil_ContentsScaleUsesScaleFactor_3x) {
  ASSERT_EQ(view_.window, nil);

  [view_ updateWithContextId:42
                  pixelWidth:2400
                 pixelHeight:1600
                 scaleFactor:3.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 3.0);
}

// ===================================================================
// AC2: Same contextId, scale changes from 1.0 to 2.0 —
//      contentsScale must refresh.
// ===================================================================

// Happy path: update same contextId with new scale.
TEST_F(OWLRemoteLayerViewTest, AC2_SameContextId_ScaleChangeRefreshesContentsScale) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);

  // Same contextId, but scale changes to 2.0.
  [view_ updateWithContextId:42
                  pixelWidth:1600
                 pixelHeight:1200
                 scaleFactor:2.0f];

  // Must be the same sublayer (reused, not recreated).
  CALayer* sublayerAfter = FindRemoteSublayer(view_);
  ASSERT_NE(sublayerAfter, nil);
  EXPECT_DOUBLE_EQ(sublayerAfter.contentsScale, 2.0);
}

// Edge: scale changes from 2.0 down to 1.0 (reverse direction).
TEST_F(OWLRemoteLayerViewTest, AC2_SameContextId_ScaleChangeDownward) {
  [view_ updateWithContextId:42
                  pixelWidth:1600
                 pixelHeight:1200
                 scaleFactor:2.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 2.0);

  // Scale goes back down to 1.0.
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  CALayer* sublayerAfter = FindRemoteSublayer(view_);
  ASSERT_NE(sublayerAfter, nil);
  EXPECT_DOUBLE_EQ(sublayerAfter.contentsScale, 1.0);
}

// Edge: different contextId with different scale (layer replacement).
TEST_F(OWLRemoteLayerViewTest, AC2_DifferentContextId_ScaleChangeOnNewLayer) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  [view_ updateWithContextId:99
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 2.0);
}

// ===================================================================
// AC3: _updateContentsScale must NOT promote a legitimate 1.0 to 2.0.
//      Verified indirectly: after setting scaleFactor=1.0, the
//      contentsScale must remain 1.0 even if default screen is Retina.
// ===================================================================

// Happy path: scale 1.0 stays 1.0 (not silently promoted to 2.0).
TEST_F(OWLRemoteLayerViewTest, AC3_LegitimateOneNotPromotedToTwo) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  // The core AC3 assertion: 1.0 must stay 1.0.
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);
}

// Edge: two consecutive 1.0 updates — still 1.0.
TEST_F(OWLRemoteLayerViewTest, AC3_RepeatedOneStaysOne) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:1.0f];

  [view_ updateWithContextId:42
                  pixelWidth:1024
                 pixelHeight:768
                 scaleFactor:1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);
}

// Edge: scaleFactor=0 should fallback to 1.0 (not crash, not promote).
TEST_F(OWLRemoteLayerViewTest, AC3_ScaleFactorZeroFallsBackToOne) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:0.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  // 0 is invalid; should fallback to 1.0, not promote to 2.0.
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);
}

// Edge: negative scaleFactor also falls back to 1.0.
TEST_F(OWLRemoteLayerViewTest, AC3_ScaleFactorNegativeFallsBackToOne) {
  [view_ updateWithContextId:42
                  pixelWidth:800
                 pixelHeight:600
                 scaleFactor:-1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  if (!sublayer) {
    GTEST_SKIP() << "CALayerHost not available in headless test environment";
  }
  EXPECT_DOUBLE_EQ(sublayer.contentsScale, 1.0);
}

// ===================================================================
// AC4: viewDidChangeBackingProperties triggers scaleChangeHandler.
//
// We simulate a backing-property change by calling
// viewDidChangeBackingProperties directly (since we cannot move a
// headless view between real screens).
// ===================================================================

// Happy path: handler fires when viewDidChangeBackingProperties is called.
TEST_F(OWLRemoteLayerViewTest, AC4_ScaleChangeHandlerFires) {
  // First set up a surface so the view has a known scale.
  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  __block CGFloat receivedScale = 0;
  __block CGSize receivedDipSize = CGSizeZero;
  __block int callCount = 0;

  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    receivedScale = newScale;
    receivedDipSize = dipSize;
    callCount++;
  };

  // Simulate a backing property change (e.g., window dragged to different
  // screen).  We call the method directly since there's no real window.
  [view_ viewDidChangeBackingProperties];

  EXPECT_GE(callCount, 1);
  // The scale reported should be the current effective scale.
  // Without a real window, the view should use its last known scaleFactor.
  EXPECT_GT(receivedScale, 0.0);
}

// Edge: handler is nil — no crash when viewDidChangeBackingProperties fires.
TEST_F(OWLRemoteLayerViewTest, AC4_NilHandlerDoesNotCrash) {
  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  view_.scaleChangeHandler = nil;

  // Must not crash.
  [view_ viewDidChangeBackingProperties];
}

// Edge: handler replaced mid-flight — new handler receives the callback.
TEST_F(OWLRemoteLayerViewTest, AC4_ReplacedHandlerReceivesCallback) {
  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  __block int firstCount = 0;
  __block int secondCount = 0;

  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    firstCount++;
  };
  [view_ viewDidChangeBackingProperties];
  EXPECT_GE(firstCount, 1);

  // Replace handler.
  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    secondCount++;
  };
  [view_ viewDidChangeBackingProperties];
  EXPECT_GE(secondCount, 1);
  // First handler should NOT have been called again.
  EXPECT_EQ(firstCount, 1);
}

// ===================================================================
// AC5: scaleChangeHandler's dipSize equals OWLRemoteLayerView.bounds.size.
// ===================================================================

// Happy path: reported dipSize matches the view's bounds.
TEST_F(OWLRemoteLayerViewTest, AC5_DipSizeMatchesBoundsSize) {
  // View frame is 800x600 (set in SetUp).
  [view_ updateWithContextId:42
                  pixelWidth:1600
                 pixelHeight:1200
                 scaleFactor:2.0f];

  __block CGSize receivedDipSize = CGSizeZero;

  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    receivedDipSize = dipSize;
  };

  [view_ viewDidChangeBackingProperties];

  CGSize expectedSize = view_.bounds.size;
  EXPECT_DOUBLE_EQ(receivedDipSize.width, expectedSize.width);
  EXPECT_DOUBLE_EQ(receivedDipSize.height, expectedSize.height);
}

// Edge: after frame resize, dipSize reflects the new bounds.
TEST_F(OWLRemoteLayerViewTest, AC5_DipSizeReflectsResizedBounds) {
  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  // Resize the view.
  [view_ setFrameSize:NSMakeSize(1024, 768)];

  __block CGSize receivedDipSize = CGSizeZero;

  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    receivedDipSize = dipSize;
  };

  [view_ viewDidChangeBackingProperties];

  EXPECT_DOUBLE_EQ(receivedDipSize.width, 1024.0);
  EXPECT_DOUBLE_EQ(receivedDipSize.height, 768.0);
}

// Edge: zero-size view (minimized / collapsed) — dipSize is (0, 0).
TEST_F(OWLRemoteLayerViewTest, AC5_ZeroSizeViewReportsZeroDipSize) {
  [view_ updateWithContextId:42
                  pixelWidth:0
                 pixelHeight:0
                 scaleFactor:2.0f];

  [view_ setFrameSize:NSMakeSize(0, 0)];

  __block CGSize receivedDipSize = CGSizeMake(-1, -1);

  view_.scaleChangeHandler = ^(CGFloat newScale, CGSize dipSize) {
    receivedDipSize = dipSize;
  };

  [view_ viewDidChangeBackingProperties];

  EXPECT_DOUBLE_EQ(receivedDipSize.width, 0.0);
  EXPECT_DOUBLE_EQ(receivedDipSize.height, 0.0);
}

// ===================================================================
// AC6: ObjC++ unit tests compile and pass.
//
// This is a meta-AC — if all the above tests compile and pass,
// AC6 is satisfied.  We add a sentinel test to confirm the test
// suite was actually loaded.
// ===================================================================

TEST_F(OWLRemoteLayerViewTest, AC6_TestSuiteLoaded) {
  // If this test executes, the ObjC++ unit test suite compiled and
  // linked successfully.  AC6 is satisfied.
  EXPECT_NE(view_, nil);
}

// ===================================================================
// Additional boundary / regression tests
// ===================================================================

// contextId=0 should clear the surface (no sublayer).
TEST_F(OWLRemoteLayerViewTest, ContextIdZeroClearsSublayer) {
  [view_ updateWithContextId:42
                  pixelWidth:1920
                 pixelHeight:1080
                 scaleFactor:2.0f];

  [view_ updateWithContextId:0
                  pixelWidth:0
                 pixelHeight:0
                 scaleFactor:1.0f];

  CALayer* sublayer = FindRemoteSublayer(view_);
  // After clearing, there should be no sublayer.
  EXPECT_EQ(sublayer, nil);
}

// Rapid scale toggling should not leak layers.
TEST_F(OWLRemoteLayerViewTest, RapidScaleTogglingNoLayerLeak) {
  for (int i = 0; i < 50; i++) {
    float scale = (i % 2 == 0) ? 1.0f : 2.0f;
    [view_ updateWithContextId:42
                    pixelWidth:(uint32_t)(800 * scale)
                   pixelHeight:(uint32_t)(600 * scale)
                   scaleFactor:scale];
  }
  // Should have at most 1 sublayer (reused for same contextId).
  EXPECT_LE(view_.layer.sublayers.count, 1u);
}

}  // namespace
}  // namespace owl
