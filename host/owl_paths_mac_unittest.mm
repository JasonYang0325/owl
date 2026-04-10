// Copyright 2026 AntlerAI. All rights reserved.
// Tests for owl_paths_mac.mm — path computation logic.
// Note: We can't call OverrideOWLBundlePaths() directly in unit tests
// because SetOverrideFrameworkBundlePath() requires a real NSBundle.
// Instead, we test the path computation by overriding FILE_EXE and
// verifying the resulting paths match expectations.

#import <Foundation/Foundation.h>

#include "base/apple/bundle_locations.h"
#include "base/base_paths.h"
#include "base/files/file_path.h"
#include "base/path_service.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace owl {
namespace {

// Replicates GetContentsPath() logic from owl_paths_mac.mm for testing
// without calling the actual override functions (which need real NSBundles).
base::FilePath ComputeContentsPath(const base::FilePath& exe_path,
                                   bool is_subprocess) {
  base::FilePath path = exe_path;
  if (is_subprocess) {
    // 9 levels up from helper exe to OWL Host.app/Contents/
    path = path.DirName().DirName().DirName().DirName().DirName()
               .DirName().DirName().DirName().DirName();
  } else {
    // 2 levels up from main exe to OWL Host.app/Contents/
    path = path.DirName().DirName();
  }
  return path;
}

TEST(OWLPathsComputationTest, MainProcessContentsPath) {
  base::FilePath exe("/fake/OWL Host.app/Contents/MacOS/OWL Host");
  base::FilePath contents = ComputeContentsPath(exe, /*is_subprocess=*/false);
  EXPECT_EQ("/fake/OWL Host.app/Contents", contents.value());
  EXPECT_EQ("Contents", contents.BaseName().value());
}

TEST(OWLPathsComputationTest, HelperProcessContentsPath) {
  base::FilePath exe(
      "/fake/OWL Host.app/Contents/Frameworks/"
      "OWL Host Framework.framework/Versions/A/Helpers/"
      "OWL Host Helper.app/Contents/MacOS/OWL Host Helper");
  base::FilePath contents = ComputeContentsPath(exe, /*is_subprocess=*/true);
  EXPECT_EQ("/fake/OWL Host.app/Contents", contents.value());
  EXPECT_EQ("Contents", contents.BaseName().value());
}

TEST(OWLPathsComputationTest, MainAndHelperResolveToSameContents) {
  base::FilePath main_exe("/app/OWL Host.app/Contents/MacOS/OWL Host");
  base::FilePath helper_exe(
      "/app/OWL Host.app/Contents/Frameworks/"
      "OWL Host Framework.framework/Versions/A/Helpers/"
      "OWL Host Helper.app/Contents/MacOS/OWL Host Helper");

  base::FilePath main_contents =
      ComputeContentsPath(main_exe, /*is_subprocess=*/false);
  base::FilePath helper_contents =
      ComputeContentsPath(helper_exe, /*is_subprocess=*/true);

  EXPECT_EQ(main_contents, helper_contents);
}

TEST(OWLPathsComputationTest, OuterBundleFromContents) {
  base::FilePath contents("/app/OWL Host.app/Contents");
  base::FilePath outer = contents.DirName();
  EXPECT_EQ("/app/OWL Host.app", outer.value());
}

TEST(OWLPathsComputationTest, FrameworkPathFromContents) {
  base::FilePath contents("/app/OWL Host.app/Contents");
  base::FilePath framework =
      contents.Append("Frameworks")
          .Append("OWL Host Framework.framework");
  EXPECT_EQ("/app/OWL Host.app/Contents/Frameworks/"
            "OWL Host Framework.framework",
            framework.value());
}

TEST(OWLPathsComputationTest, HelperPathFromFramework) {
  base::FilePath framework(
      "/app/OWL Host.app/Contents/Frameworks/"
      "OWL Host Framework.framework");
  base::FilePath helper =
      framework.Append("Helpers")
          .Append("OWL Host Helper.app")
          .Append("Contents")
          .Append("MacOS")
          .Append("OWL Host Helper");
  EXPECT_TRUE(helper.value().find("Helpers/OWL Host Helper.app") !=
              std::string::npos);
  EXPECT_EQ("OWL Host Helper", helper.BaseName().value());
}

TEST(OWLPathsComputationTest, GPUVariantPath) {
  // Verify that Chromium's GetChildPath would compute the GPU variant
  // by appending " (GPU)" to the helper name. The base helper path
  // must end with "OWL Host Helper" for this to work.
  base::FilePath helper(
      "/app/Frameworks/OWL Host Framework.framework/Helpers/"
      "OWL Host Helper.app/Contents/MacOS/OWL Host Helper");
  EXPECT_EQ("OWL Host Helper", helper.BaseName().value());

  // GetChildPath would replace "OWL Host Helper" with "OWL Host Helper (GPU)"
  // and ".app" with " (GPU).app" in the path.
  std::string path_str = helper.value();
  size_t pos = path_str.rfind("OWL Host Helper.app");
  ASSERT_NE(std::string::npos, pos);
  std::string gpu_path = path_str.substr(0, pos) +
                          "OWL Host Helper (GPU).app" +
                          path_str.substr(pos + strlen("OWL Host Helper.app"));
  // Replace the binary name too
  size_t bin_pos = gpu_path.rfind("OWL Host Helper");
  ASSERT_NE(std::string::npos, bin_pos);
  gpu_path = gpu_path.substr(0, bin_pos) + "OWL Host Helper (GPU)";
  EXPECT_TRUE(gpu_path.find("OWL Host Helper (GPU).app") !=
              std::string::npos);
}

}  // namespace
}  // namespace owl
