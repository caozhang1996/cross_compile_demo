// fast_check_chessboard/main.cpp
// 目标：对 test_images 目录下的图像做棋盘格检测（快速预检）。
// 实现：复制 ustereo_calibrate/cpp/cv_utils.cpp 的 FastCheckChessboardCorners，
//       遍历目录里所有图片，逐张调用，打印"有/无棋盘格"。
//
// 用法：
//   main <image_dir> [board_width] [board_height]
//   例：main test_images 11 8
//   默认 image_dir=test_images，board_size=(11,8)（与熟练工程 ustereo_calibrate
//   一致）。

#include <filesystem>
#include <iostream>
#include <string>
#include <vector>

#include <opencv2/opencv.hpp>

namespace fs = std::filesystem;

// ── 快速棋盘格检测：只回答"图上有没有棋盘"，不做角点精定位 ──────────
// 来源：ustereo_calibrate/cpp/cv_utils.cpp
// board_size = (width, height) = 棋盘格内角点数（不是方格数！）
bool FastCheckChessboardCorners(const cv::Mat &image,
                                const cv::Size &board_size)
{
  cv::Mat gray;
  if (image.channels() == 3)
  {
    cv::cvtColor(image, gray, cv::COLOR_BGR2GRAY);
  }
  else
  {
    gray = image;
  }

  std::vector<cv::Point2f> corners;
  bool found = cv::findChessboardCorners(
      gray, board_size, corners,
      cv::CALIB_CB_FAST_CHECK | cv::CALIB_CB_ADAPTIVE_THRESH);

  return found;
}

// 递归收集目录下所有 png/jpg/jpeg 图片
std::vector<fs::path> CollectImages(const fs::path &dir)
{
  std::vector<fs::path> imgs;
  if (!fs::exists(dir))
  {
    std::cerr << "[ERROR] 目录不存在: " << dir << std::endl;
    return imgs;
  }

  for (const auto &entry : fs::recursive_directory_iterator(dir))
  {
    if (!entry.is_regular_file()) continue;
    std::string ext = entry.path().extension().string();
    if (ext == ".png" || ext == ".jpg" || ext == ".jpeg")
      imgs.push_back(entry.path());
  }
  std::sort(imgs.begin(), imgs.end());  // 让输出顺序稳定
  return imgs;
}

int main(int argc, char *argv[])
{
  // ── 参数解析（都很薄，够用即可）────────────────────────────
  fs::path image_dir = "test_images";
  int board_width = 11;
  int board_height = 8;

  if (argc >= 2) image_dir = argv[1];
  if (argc >= 3) board_width = std::stoi(argv[2]);
  if (argc >= 4) board_height = std::stoi(argv[3]);

  const cv::Size board_size(board_width, board_height);
  std::cout << "棋盘格规格(内角): " << board_size.width << " x "
            << board_size.height << "\n"
            << "图像目录          : " << image_dir << "\n"
            << "----------------------------------------\n";

  auto images = CollectImages(image_dir);
  if (images.empty())
  {
    std::cerr << "[ERROR] 目录下没有找到 png/jpg 图片: " << image_dir
              << std::endl;
    return -1;
  }

  int total = 0, with_board = 0;
  for (const auto &path : images)
  {
    cv::Mat img = cv::imread(path.string());
    if (img.empty())
    {
      std::cout << "[无法读取] " << path.string() << std::endl;
      continue;
    }

    total++;
    bool found = FastCheckChessboardCorners(img, board_size);
    if (found) with_board++;

    std::cout << (found ? "[有棋盘格  ] " : "[无棋盘格  ] ") << path.string()
              << std::endl;
  }

  std::cout << "----------------------------------------\n"
            << "共 " << total << " 张，检测到棋盘格 " << with_board
            << " 张。\n";

  // 提示：FAST_CHECK 是快速粗判，可能"漏检"（把真有的误判为没有）。
  // 若要更准，改用 CALIB_CB_FILTER_QUADS（正式标定用的完整检测）。
  return 0;
}