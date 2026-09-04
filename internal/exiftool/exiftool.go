package exiftool

import (
	"bytes"
	"cmp"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/vincentchyu/photools/internal/domain"
	"github.com/vincentchyu/photools/internal/logger"
)

type Metadata = domain.Metadata

type CommandRunner interface {
	CombinedOutput(name string, args ...string) ([]byte, error)
}

type ExecRunner struct{}

func (ExecRunner) CombinedOutput(name string, args ...string) ([]byte, error) {
	start := time.Now()
	var out []byte
	var err error
	if name == "exiftool" || strings.HasSuffix(name, "/exiftool") {
		cfgPath := EnsureConfigFile()
		if cfgPath != "" {
			var newArgs []string
			newArgs = append(newArgs, "-config", cfgPath)
			newArgs = append(newArgs, args...)
			out, err = exec.Command(name, newArgs...).CombinedOutput()
		} else {
			out, err = exec.Command(name, args...).CombinedOutput()
		}
	} else {
		out, err = exec.Command(name, args...).CombinedOutput()
	}
	if err != nil {
		logger.Debugf(
			"ExifTool进程", "直接执行报错: %s %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(name), strings.Join(args, " "), err, strings.TrimSpace(string(out)), time.Since(start),
		)
	}
	return out, err
}

// ReadMetadata 读取基础 EXIF 元数据
func ReadMetadata(runner CommandRunner, path string) (Metadata, error) {
	start := time.Now()
	output, err := runner.CombinedOutput(
		"exiftool", "-m", "-q", "-json", "-DateTimeOriginal", "-OffsetTimeOriginal", "-GPSPosition", "-GPSDateTime",
		path,
	)
	if len(output) > 0 {
		if meta, parseErr := ParseMetadataJSON(output); parseErr == nil {
			logger.Debugf(
				"ExifTool读取-元数据", "成功读取: %s (时间: %s, 坐标: %s, 耗时: %v)",
				filepath.Base(path), meta.DateTimeOriginal, meta.GPSPosition, time.Since(start),
			)
			return meta, nil
		}
	}
	if err != nil {
		readErr := fmt.Errorf("exiftool 读取元数据失败: %w", err)
		logger.Errorf(
			"ExifTool读取-元数据", "读取失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(path), readErr, strings.TrimSpace(string(output)), time.Since(start),
		)
		return Metadata{}, readErr
	}
	meta, parseErr := ParseMetadataJSON(output)
	if parseErr != nil {
		logger.Errorf(
			"ExifTool读取-元数据", "解析元数据 JSON 失败: %s -> %v (耗时: %v)",
			filepath.Base(path), parseErr, time.Since(start),
		)
		return Metadata{}, parseErr
	}
	logger.Debugf(
		"ExifTool读取-元数据", "成功读取: %s (时间: %s, 坐标: %s, 耗时: %v)",
		filepath.Base(path), meta.DateTimeOriginal, meta.GPSPosition, time.Since(start),
	)
	return meta, nil
}

// ReadBatchMetadataMap 批量读取多个照片文件的元数据，返回以规范化路径为 key 的映射
func ReadBatchMetadataMap(runner CommandRunner, paths []string) (map[string]Metadata, error) {
	return ReadBatchMetadataMapConcurrent(runner, paths, 8, nil)
}

// ReadBatchMetadataMapConcurrent 并发分批读取多个照片文件的元数据，支持多 Worker 并行与进度实时回调
func ReadBatchMetadataMapConcurrent(
	runner CommandRunner, paths []string, concurrency int, onProgress func(processed, total int),
) (map[string]Metadata, error) {
	if len(paths) == 0 {
		return map[string]Metadata{}, nil
	}

	batchStart := time.Now()
	if concurrency <= 0 {
		concurrency = 8
	}

	const batchSize = 250
	type batchChunk struct {
		chunk []string
	}

	var chunks []batchChunk
	for i := 0; i < len(paths); i += batchSize {
		end := min(i+batchSize, len(paths))
		chunks = append(chunks, batchChunk{chunk: paths[i:end]})
	}

	var mu sync.Mutex
	result := make(map[string]Metadata, len(paths))
	var processedCount atomic.Int64
	total := len(paths)

	actualWorkers := min(concurrency, len(chunks))
	logger.Infof(
		"ExifTool读取-批量", "开始批量并发预读 %d 个文件元数据 (分块: %d 块, 并发 Worker: %d)",
		total, len(chunks), actualWorkers,
	)

	var wg sync.WaitGroup
	chunkChan := make(chan batchChunk, len(chunks))
	for _, c := range chunks {
		chunkChan <- c
	}
	close(chunkChan)

	for range actualWorkers {
		wg.Go(
			func() {
				for item := range chunkChan {
					chunkStart := time.Now()
					args := []string{
						"-m", "-q", "-json", "-DateTimeOriginal", "-OffsetTimeOriginal", "-GPSPosition", "-GPSDateTime",
					}
					args = append(args, item.chunk...)

					output, _ := runner.CombinedOutput("exiftool", args...)
					parsedCount := 0
					if len(output) > 0 {
						records, parseErr := ParseBatchMetadataJSON(output)
						if parseErr == nil && len(records) > 0 {
							parsedCount = len(records)
							mu.Lock()
							for idx, rec := range records {
								filePath := rec.SourceFile
								if filePath == "" && idx < len(item.chunk) {
									filePath = item.chunk[idx]
								}
								if filePath != "" {
									cleanPath := filepath.Clean(filePath)
									result[cleanPath] = rec
									if abs, err := filepath.Abs(filePath); err == nil {
										result[abs] = rec
									}
								}
							}
							mu.Unlock()
						}
					}

					logger.Debugf(
						"ExifTool读取-批量", "分块预读完成 (%d 个文件, 成功解析 %d 条, 耗时: %v)",
						len(item.chunk), parsedCount, time.Since(chunkStart),
					)

					done := min(int(processedCount.Add(int64(len(item.chunk)))), total)
					if onProgress != nil {
						onProgress(done, total)
					}
				}
			},
		)
	}

	wg.Wait()
	logger.Infof(
		"ExifTool读取-批量", "批量并发预读完成: 成功加载 %d/%d 组元数据 (总耗时: %v)",
		len(result), total, time.Since(batchStart),
	)
	return result, nil
}

// ParseBatchMetadataJSON 解析 exiftool -json 多文件输出（允许空数组返回空切片，且自动容错剥离 Warning 文本）
func ParseBatchMetadataJSON(output []byte) ([]Metadata, error) {
	cleanOutput := bytes.TrimSpace(output)
	if len(cleanOutput) == 0 {
		return nil, nil
	}

	// 自动容错剥离 ExifTool 输出前面的 Warning 或非 JSON 前缀
	// 需精准找到后面紧随 '{' 或 ']' 的有效 JSON 数组 '['
	jsonStart := -1
	for i := 0; i < len(cleanOutput); i++ {
		if cleanOutput[i] == '[' {
			rest := bytes.TrimSpace(cleanOutput[i+1:])
			if len(rest) > 0 && (rest[0] == '{' || rest[0] == ']') {
				jsonStart = i
				break
			}
		}
	}

	if jsonStart >= 0 {
		if end := bytes.LastIndexByte(cleanOutput, ']'); end > jsonStart {
			cleanOutput = cleanOutput[jsonStart : end+1]
		}
	}

	var records []Metadata
	if err := json.Unmarshal(cleanOutput, &records); err != nil {
		return nil, fmt.Errorf("解析 exiftool 批量输出失败: %w (原始输出: %s)", err, string(bytes.TrimSpace(output)))
	}
	return records, nil
}

// ParseMetadataJSON 解析 exiftool -json 输出
func ParseMetadataJSON(output []byte) (Metadata, error) {
	records, err := ParseBatchMetadataJSON(output)
	if err != nil {
		return Metadata{}, err
	}
	if len(records) == 0 {
		return Metadata{}, errors.New("exiftool 未返回任何元数据")
	}
	return records[0], nil
}

// ClassifyFailure 分析 exiftool 执行失败原因并输出用户友好的提示
func ClassifyFailure(output []byte, err error) string {
	text := strings.ToLower(string(bytes.TrimSpace(output)))
	switch {
	case strings.Contains(text, "no track points found"), strings.Contains(text, "gps track is empty"):
		return "照片时间未落在轨迹范围内，未写入有效 GPS 信息。"
	case strings.Contains(text, "empty track file"):
		return "GPX 轨迹文件为空或无法读取。"
	case strings.Contains(text, "file not found"):
		return "底层工具未找到待处理文件。"
	case err != nil:
		return fmt.Sprintf("调用 exiftool 失败：%v", err)
	default:
		return "未写入有效 GPS 信息。"
	}
}

// ==========================================
// 1. GPX 轨迹匹配与 GPS 经纬度操作 (Cap 1)
// ==========================================

// WriteGeotag 调用 exiftool 匹配 GPX 轨迹写入照片 GPS 经纬度
func WriteGeotag(runner CommandRunner, rawPath string, gpxFiles []string, geosync string) ([]byte, error) {
	start := time.Now()
	logger.Infof(
		"ExifTool写入-GPX", "开始匹配 GPX 轨迹写入原图: %s (GPX: %s, geosync: %s)",
		filepath.Base(rawPath), strings.Join(gpxFiles, ", "), geosync,
	)

	args := []string{
		"-overwrite_original",
		"-P",
		"-api", "GeoMaxIntSecs=1800",
		"-api", "GeoMaxExtSecs=1800",
		fmt.Sprintf("-geosync=%s", geosync),
	}

	for _, gpx := range gpxFiles {
		args = append(args, "-geotag", gpx)
	}

	args = append(args, rawPath)
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		logger.Errorf(
			"ExifTool写入-GPX", "GPX 写入原图失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(rawPath), err, strings.TrimSpace(string(out)), time.Since(start),
		)
	} else {
		logger.Successf(
			"ExifTool写入-GPX", "GPX 写入原图成功: %s (耗时: %v)",
			filepath.Base(rawPath), time.Since(start),
		)
	}
	return out, err
}

// WriteGeotagToXMP 🌟 匹配 GPX 轨迹并直接写入/生成 XMP 侧车文件 (Sidecar-Only 模式专用，不触碰原图)
func WriteGeotagToXMP(runner CommandRunner, sourceMedia, xmpPath string, gpxFiles []string, geosync string) (
	[]byte, error,
) {
	start := time.Now()
	logger.Infof(
		"ExifTool写入-GPX", "开始匹配 GPX 轨迹写入 XMP 侧车: %s (源媒体: %s, GPX: %s)",
		filepath.Base(xmpPath), filepath.Base(sourceMedia), strings.Join(gpxFiles, ", "),
	)

	args := []string{
		"-overwrite_original",
		"-P",
		"-api", "GeoMaxIntSecs=1800",
		"-api", "GeoMaxExtSecs=1800",
		fmt.Sprintf("-geosync=%s", geosync),
		"-TagsFromFile", sourceMedia,
	}

	for _, gpx := range gpxFiles {
		args = append(args, "-geotag", gpx)
	}

	args = append(args, xmpPath)
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		logger.Errorf(
			"ExifTool写入-GPX", "GPX 写入 XMP 侧车失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(xmpPath), err, strings.TrimSpace(string(out)), time.Since(start),
		)
	} else {
		logger.Successf(
			"ExifTool写入-GPX", "GPX 写入 XMP 侧车成功: %s (耗时: %v)",
			filepath.Base(xmpPath), time.Since(start),
		)
	}
	return out, err
}

// WriteCoordinates 直接为照片文件写入指定的 GPS 经纬度与海拔（用于智能插值与手动标记）
func WriteCoordinates(runner CommandRunner, filePath string, lat, lon, alt float64) error {
	start := time.Now()
	logger.Infof(
		"ExifTool写入-坐标", "写入照片 GPS 坐标: %s (%.6f, %.6f, %.1fm)",
		filepath.Base(filePath), lat, lon, alt,
	)

	latRef := "N"
	absLat := lat
	if lat < 0 {
		latRef = "S"
		absLat = -lat
	}

	lonRef := "E"
	absLon := lon
	if lon < 0 {
		lonRef = "W"
		absLon = -lon
	}

	args := []string{
		"-overwrite_original",
		"-P",
		fmt.Sprintf("-GPSLatitude=%.6f", absLat),
		fmt.Sprintf("-GPSLatitudeRef=%s", latRef),
		fmt.Sprintf("-GPSLongitude=%.6f", absLon),
		fmt.Sprintf("-GPSLongitudeRef=%s", lonRef),
	}

	if alt != 0 {
		altRef := "0" // 0 = 海拔高于海平面 (Above sea level)
		absAlt := alt
		if alt < 0 {
			altRef = "1" // 1 = 海拔低于海平面 (Below sea level)
			absAlt = -alt
		}
		args = append(
			args,
			fmt.Sprintf("-GPSAltitude=%.2f", absAlt),
			fmt.Sprintf("-GPSAltitudeRef=%s", altRef),
		)
	}

	args = append(args, filePath)
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		wErr := fmt.Errorf("写入 GPS 经纬度坐标失败: %w", err)
		logger.Errorf(
			"ExifTool写入-坐标", "写入照片坐标失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(filePath), wErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return wErr
	}
	logger.Successf(
		"ExifTool写入-坐标", "写入照片坐标成功: %s (耗时: %v)",
		filepath.Base(filePath), time.Since(start),
	)
	return nil
}

// WriteCoordinatesToXMP 🌟 直接向 XMP 侧车文件写入指定的 GPS 经纬度与海拔（Sidecar-Only 模式专用）
func WriteCoordinatesToXMP(runner CommandRunner, xmpPath string, lat, lon, alt float64) error {
	start := time.Now()
	logger.Infof(
		"ExifTool写入-坐标", "写入 XMP 侧车 GPS 坐标: %s (%.6f, %.6f, %.1fm)",
		filepath.Base(xmpPath), lat, lon, alt,
	)

	latRef := "N"
	absLat := lat
	if lat < 0 {
		latRef = "S"
		absLat = -lat
	}

	lonRef := "E"
	absLon := lon
	if lon < 0 {
		lonRef = "W"
		absLon = -lon
	}

	args := []string{
		"-overwrite_original",
		"-P",
		fmt.Sprintf("-XMP-exif:GPSLatitude=%.6f %s", absLat, latRef),
		fmt.Sprintf("-XMP-exif:GPSLongitude=%.6f %s", absLon, lonRef),
		"-XMP-exif:GPSVersionID=2.3.0.0",
		"-XMP-exif:GPSMapDatum=WGS-84",
	}

	if alt != 0 {
		altRef := "0" // 0 = Above Sea Level
		absAlt := alt
		if alt < 0 {
			altRef = "1" // 1 = Below Sea Level
			absAlt = -alt
		}
		args = append(
			args,
			fmt.Sprintf("-XMP-exif:GPSAltitude=%.2f", absAlt),
			fmt.Sprintf("-XMP-exif:GPSAltitudeRef=%s", altRef),
		)
	}

	args = append(args, xmpPath)
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		wErr := fmt.Errorf("写入 GPS 坐标到 XMP 侧车文件失败: %w", err)
		logger.Errorf(
			"ExifTool写入-坐标", "写入 XMP 侧车坐标失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(xmpPath), wErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return wErr
	}
	logger.Successf(
		"ExifTool写入-坐标", "写入 XMP 侧车坐标成功: %s (耗时: %v)",
		filepath.Base(xmpPath), time.Since(start),
	)
	return nil
}

// BuildProvenanceArgs 构造 Photools 专属可追溯性元数据与 XMP 审计指纹参数
func BuildProvenanceArgs(prov domain.GPSProvenance) []string {
	var args []string
	processor := prov.Processor
	if processor == "" {
		processor = domain.DefaultProcessorName
	}
	ts := prov.Timestamp
	if ts == "" {
		ts = time.Now().Format(time.RFC3339)
	}

	if prov.Source != "" {
		args = append(args, fmt.Sprintf("-XMP-photools:GPSSource=%s", prov.Source))
	}
	args = append(
		args,
		fmt.Sprintf("-XMP-photools:Processor=%s", processor),
		fmt.Sprintf("-XMP-photools:ProcessedDate=%s", ts),
		fmt.Sprintf("-XMP-xmp:CreatorTool=%s", processor),
		fmt.Sprintf("-XMP-xmp:MetadataDate=%s", ts),
	)
	if prov.MatchMethod != "" {
		args = append(args, fmt.Sprintf("-XMP-photools:GPSMatchMethod=%s", prov.MatchMethod))
	}
	if prov.Window != "" {
		args = append(args, fmt.Sprintf("-XMP-photools:InterpolateWindow=%s", prov.Window))
	}
	return args
}

// WriteCoordinatesToXMPWithProvenance 向 XMP 侧车写入 GPS 坐标并追加 Photools 溯源指纹
func WriteCoordinatesToXMPWithProvenance(
	runner CommandRunner, xmpPath string, lat, lon, alt float64, prov domain.GPSProvenance,
) error {
	start := time.Now()
	logger.Infof(
		"ExifTool写入-坐标", "写入带指纹的 XMP 侧车 GPS 坐标: %s (%.6f, %.6f, %.1fm, 来源: %s)",
		filepath.Base(xmpPath), lat, lon, alt, prov.Source,
	)

	latRef := "N"
	absLat := lat
	if lat < 0 {
		latRef = "S"
		absLat = -lat
	}

	lonRef := "E"
	absLon := lon
	if lon < 0 {
		lonRef = "W"
		absLon = -lon
	}

	args := []string{
		"-overwrite_original",
		"-P",
		fmt.Sprintf("-XMP-exif:GPSLatitude=%.6f %s", absLat, latRef),
		fmt.Sprintf("-XMP-exif:GPSLongitude=%.6f %s", absLon, lonRef),
		"-XMP-exif:GPSVersionID=2.3.0.0",
		"-XMP-exif:GPSMapDatum=WGS-84",
	}

	if alt != 0 {
		altRef := "0"
		absAlt := alt
		if alt < 0 {
			altRef = "1"
			absAlt = -alt
		}
		args = append(
			args,
			fmt.Sprintf("-XMP-exif:GPSAltitude=%.2f", absAlt),
			fmt.Sprintf("-XMP-exif:GPSAltitudeRef=%s", altRef),
		)
	}

	provArgs := BuildProvenanceArgs(prov)
	args = append(args, provArgs...)
	args = append(args, xmpPath)

	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		wErr := fmt.Errorf("写入带溯源指纹的 GPS 到 XMP 侧车文件失败: %w", err)
		logger.Errorf(
			"ExifTool写入-坐标", "写入带指纹 XMP 失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(xmpPath), wErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return wErr
	}
	logger.Successf(
		"ExifTool写入-坐标", "写入带指纹 XMP 成功: %s (耗时: %v)",
		filepath.Base(xmpPath), time.Since(start),
	)
	return nil
}

// SyncGPSToJPG 将 RAW 中的 GPS 经纬度信息同步到伴随的 JPG 文件（仅同步 GPS，不侵入其他元数据）
func SyncGPSToJPG(runner CommandRunner, sourceRaw, targetJPG string) error {
	start := time.Now()
	logger.Infof(
		"ExifTool同步-GPS", "从 RAW 同步 GPS 至伴随 JPG: %s -> %s",
		filepath.Base(sourceRaw), filepath.Base(targetJPG),
	)

	out, err := runner.CombinedOutput(
		"exiftool", "-overwrite_original", "-P", "-TagsFromFile", sourceRaw,
		"-GPS:all",
		targetJPG,
	)
	if err != nil {
		sErr := fmt.Errorf("同步 GPS 经纬度到 JPG 失败：%w", err)
		logger.Errorf(
			"ExifTool同步-GPS", "同步 GPS 到 JPG 失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(targetJPG), sErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return sErr
	}
	logger.Successf(
		"ExifTool同步-GPS", "同步 GPS 到 JPG 成功: %s (耗时: %v)",
		filepath.Base(targetJPG), time.Since(start),
	)
	return nil
}

// SyncGPSToXMP 将 RAW 中的 GPS 经纬度坐标规范化同步到伴随的 XMP 侧车文件
func SyncGPSToXMP(runner CommandRunner, sourceRaw, targetXMP string) error {
	return SyncGPSToXMPWithProvenance(runner, sourceRaw, targetXMP, domain.GPSProvenance{})
}

// SyncGPSToXMPWithProvenance 将 RAW 中的 GPS 经纬度同步到 XMP 侧车文件并可选写入溯源指纹
func SyncGPSToXMPWithProvenance(runner CommandRunner, sourceRaw, targetXMP string, prov domain.GPSProvenance) error {
	start := time.Now()
	logger.Infof(
		"ExifTool同步-GPS", "从 RAW 同步 GPS 至伴随 XMP: %s -> %s (来源: %s)",
		filepath.Base(sourceRaw), filepath.Base(targetXMP), prov.Source,
	)

	cfgPath := EnsureConfigFile()
	args := []string{
		"-overwrite_original",
		"-P",
	}
	if cfgPath != "" {
		args = append(args, "-config", cfgPath)
	}
	args = append(
		args,
		"-TagsFromFile", sourceRaw,
		"-XMP-exif:GPSVersionID<GPSVersionID",
		"-XMP-exif:GPSLatitude<GPSLatitude",
		"-XMP-exif:GPSLongitude<GPSLongitude",
		"-XMP-exif:GPSAltitudeRef<GPSAltitudeRef",
		"-XMP-exif:GPSAltitude<GPSAltitude",
		"-XMP-exif:GPSDateTime<GPSDateTime",
		"-XMP-exif:GPSSatellites<GPSSatellites",
		"-XMP-exif:GPSMapDatum<GPSMapDatum",
	)
	if prov.Source != "" {
		provArgs := BuildProvenanceArgs(prov)
		args = append(args, provArgs...)
	}
	args = append(args, targetXMP)
	output, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		sErr := fmt.Errorf("同步 GPS 经纬度到 XMP 失败: %w (详情: %s)", err, string(output))
		logger.Errorf(
			"ExifTool同步-GPS", "同步 GPS 到 XMP 失败: %s -> %v (耗时: %v)",
			filepath.Base(targetXMP), sErr, time.Since(start),
		)
		return sErr
	}
	if bytes.Contains(output, []byte("Error:")) {
		sErr := fmt.Errorf("同步 GPS 到 XMP 发生错误: %s", string(output))
		logger.Errorf("ExifTool同步-GPS", "%v", sErr)
		return sErr
	}
	logger.Successf(
		"ExifTool同步-GPS", "同步 GPS 到 XMP 成功: %s (耗时: %v)",
		filepath.Base(targetXMP), time.Since(start),
	)
	return nil
}

// CloneAllGPSMetadata 使用 ExifTool -TagsFromFile 将源照片上的全部 GPS 标签 (GPSVersionID, GPSTimeStamp, GPSDateStamp, GPSDateTime, GPSMapDatum, GPSSatellites, GPSLatitude*, GPSLongitude*, GPSAltitude* 等) 100% 完整克隆写入目标照片
func CloneAllGPSMetadata(runner CommandRunner, sourcePath, targetPath string) error {
	start := time.Now()
	logger.Infof(
		"ExifTool克隆-GPS", "全量克隆 13+ 项物理机身 GPS: %s -> %s",
		filepath.Base(sourcePath), filepath.Base(targetPath),
	)

	output, err := runner.CombinedOutput(
		"exiftool", "-overwrite_original", "-P",
		"-TagsFromFile", sourcePath,
		"-GPS:all",
		targetPath,
	)
	if err != nil {
		cErr := fmt.Errorf("克隆全量 GPS 元数据到 %s 失败: %w (详情: %s)", targetPath, err, string(output))
		logger.Errorf("ExifTool克隆-GPS", "%v (耗时: %v)", cErr, time.Since(start))
		return cErr
	}
	if bytes.Contains(output, []byte("Error:")) {
		cErr := fmt.Errorf("克隆全量 GPS 元数据发生错误: %s", string(output))
		logger.Errorf("ExifTool克隆-GPS", "%v (耗时: %v)", cErr, time.Since(start))
		return cErr
	}
	logger.Successf(
		"ExifTool克隆-GPS", "克隆 GPS 成功: %s (耗时: %v)",
		filepath.Base(targetPath), time.Since(start),
	)
	return nil
}

// WritePhotoGPSDirectly 向后兼容薄适配器：自动探测伴随文件资产组并统一委托给全局调度引擎 WriteGPS
func WritePhotoGPSDirectly(
	runner CommandRunner, sourcePath, targetPath string, lat, lon, alt float64, prov domain.GPSProvenance,
	policy domain.SidecarPolicy,
) error {
	start := time.Now()
	if targetPath == "" {
		return errors.New("目标照片路径不能为空")
	}
	if _, err := os.Stat(targetPath); err != nil {
		return fmt.Errorf("目标照片文件不存在: %w", err)
	}

	logger.Infof(
		"ExifTool直写-GPS", "收到直接写入请求: %s (策略: %s, 坐标: %.6f, %.6f, 来源: %s)",
		filepath.Base(targetPath), policy, lat, lon, prov.Source,
	)

	if prov.Source == "" {
		prov.Source = "manual_copied"
	}
	if prov.Processor == "" {
		prov.Processor = domain.DefaultProcessorName
	}
	if prov.Timestamp == "" {
		prov.Timestamp = time.Now().Format(time.RFC3339)
	}

	asset := FindAssetGroupForPath(targetPath)
	payload := GPSWritePayload{
		SourcePhotoPath: sourcePath,
		Latitude:        lat,
		Longitude:       lon,
		Altitude:        alt,
		Provenance:      prov,
	}

	_, err := WriteGPS(runner, asset, payload, policy)
	if err != nil {
		logger.Errorf(
			"ExifTool直写-GPS", "直接写入失败: %s -> %v (耗时: %v)",
			filepath.Base(targetPath), err, time.Since(start),
		)
	} else {
		logger.Successf(
			"ExifTool直写-GPS", "直接写入完成: %s (耗时: %v)",
			filepath.Base(targetPath), time.Since(start),
		)
	}
	return err
}

// CameraPerspectivePayload 🌟 完整 3D 摄影视角元数据载荷
type CameraPerspectivePayload struct {
	Heading      float64              // 镜头水平真北朝向 (0~359.9999°)
	Pitch        float64              // 相机俯仰角 (-90° ~ +90°，平视0，抬头正，俯视负)
	Roll         float64              // 水平横滚角 (-180° ~ +180°，机内水平仪)
	ViewDistance float64              // 视锥投射视距 (米，如 7200.0)
	Provenance   domain.GPSProvenance // 溯源与修改时间戳
}

// WritePerspectiveToMedia 🌟 原子函数：向媒体文件（RAW/JPG）内嵌写入完整 3D 视角元数据
// 包含 EXIF 标准真北航向、XMP-Camera 姿态角与 XMP-photools 闭环视距与溯源
func WritePerspectiveToMedia(runner CommandRunner, filePath string, payload CameraPerspectivePayload) error {
	start := time.Now()
	if filePath == "" {
		return errors.New("目标文件路径不能为空")
	}
	logger.Infof(
		"ExifTool写入-视角", "写入照片 3D 视角: %s (朝向: %.2f°, 俯仰: %.2f°, 横滚: %.2f°, 视距: %.1fm)",
		filepath.Base(filePath), payload.Heading, payload.Pitch, payload.Roll, payload.ViewDistance,
	)

	degStr := fmt.Sprintf("%.4f", payload.Heading)
	pitchStr := fmt.Sprintf("%.2f", payload.Pitch)
	rollStr := fmt.Sprintf("%.2f", payload.Roll)
	distStr := fmt.Sprintf("%.1f", payload.ViewDistance)

	timestamp := payload.Provenance.Timestamp
	if timestamp == "" {
		timestamp = time.Now().Format(time.RFC3339)
	}

	args := []string{
		"-overwrite_original",
		"-P",
		"-n",
		// 第一层：EXIF 标准真北航向（三方软件与系统照片通用）
		"-GPS:GPSImgDirection=" + degStr,
		"-GPS:GPSImgDirectionRef=T",
		// 第二层：XMP-Camera 摄影测量与 GIS 姿态规范 (Pix4D / DJI)
		"-XMP-Camera:Yaw=" + degStr,
		"-XMP-Camera:Pitch=" + pitchStr,
		"-XMP-Camera:Roll=" + rollStr,
		// 第三层：XMP-photools 闭环视距与专属溯源
		"-XMP-photools:ViewDistance=" + distStr,
		"-XMP-photools:Pitch=" + pitchStr,
		"-XMP-photools:Roll=" + rollStr,
		"-XMP-photools:AttitudeSource=" + cmp.Or(payload.Provenance.Processor, "Manual3DMap"),
		"-XMP-photools:AttitudeDate=" + timestamp,
		filePath,
	}
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		pErr := fmt.Errorf("写入完整 3D 视角至媒体文件失败: %w", err)
		logger.Errorf(
			"ExifTool写入-视角", "写入照片视角失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(filePath), pErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return pErr
	}
	logger.Successf(
		"ExifTool写入-视角", "写入照片视角成功: %s (耗时: %v)",
		filepath.Base(filePath), time.Since(start),
	)
	return nil
}

// WritePerspectiveToXMP 🌟 原子函数：向 XMP 侧车文件写入完整 3D 视角元数据
func WritePerspectiveToXMP(runner CommandRunner, xmpPath string, payload CameraPerspectivePayload) error {
	start := time.Now()
	if xmpPath == "" {
		return errors.New("XMP 侧车路径不能为空")
	}
	logger.Infof(
		"ExifTool写入-视角", "写入 XMP 侧车 3D 视角: %s (朝向: %.2f°, 俯仰: %.2f°, 横滚: %.2f°, 视距: %.1fm)",
		filepath.Base(xmpPath), payload.Heading, payload.Pitch, payload.Roll, payload.ViewDistance,
	)

	degStr := fmt.Sprintf("%.4f", payload.Heading)
	pitchStr := fmt.Sprintf("%.2f", payload.Pitch)
	rollStr := fmt.Sprintf("%.2f", payload.Roll)
	distStr := fmt.Sprintf("%.1f", payload.ViewDistance)

	timestamp := payload.Provenance.Timestamp
	if timestamp == "" {
		timestamp = time.Now().Format(time.RFC3339)
	}

	args := []string{
		"-overwrite_original",
		"-P",
		"-n",
		// 第一层：XMP-exif 标准真北航向
		"-XMP-exif:GPSImgDirection=" + degStr,
		"-XMP-exif:GPSImgDirectionRef=T",
		// 第二层：XMP-Camera 摄影测量/GIS 规范
		"-XMP-Camera:Yaw=" + degStr,
		"-XMP-Camera:Pitch=" + pitchStr,
		"-XMP-Camera:Roll=" + rollStr,
		// 第三层：XMP-photools 闭环视距与专属溯源
		"-XMP-photools:ViewDistance=" + distStr,
		"-XMP-photools:Pitch=" + pitchStr,
		"-XMP-photools:Roll=" + rollStr,
		"-XMP-photools:AttitudeSource=" + cmp.Or(payload.Provenance.Processor, "Manual3DMap"),
		"-XMP-photools:AttitudeDate=" + timestamp,
		xmpPath,
	}
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		pErr := fmt.Errorf("写入完整 3D 视角至 XMP 侧车失败: %w", err)
		logger.Errorf(
			"ExifTool写入-视角", "写入 XMP 视角失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(xmpPath), pErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return pErr
	}
	logger.Successf(
		"ExifTool写入-视角", "写入 XMP 视角成功: %s (耗时: %v)",
		filepath.Base(xmpPath), time.Since(start),
	)
	return nil
}

// VerifyPerspectiveTags 二次读取校验：确认目标文件已真实落盘有效朝向与 3D 视角字段
func VerifyPerspectiveTags(runner CommandRunner, filePath string) error {
	start := time.Now()
	if filePath == "" {
		logger.Warnf("ExifTool校验-视角", "校验路径为空")
		return errors.New("校验路径为空")
	}
	out, _ := runner.CombinedOutput("exiftool", "-m", "-q", "-s3", "-GPSImgDirection", filePath)
	dirStr := strings.TrimSpace(string(out))
	if len(dirStr) == 0 {
		err := fmt.Errorf("视角二次校验失败：未在 %s 中检测到有效 GPSImgDirection", filePath)
		logger.Errorf("ExifTool校验-视角", "%v (耗时: %v)", err, time.Since(start))
		return err
	}
	logger.Successf(
		"ExifTool校验-视角", "二次校验通过: %s (方向: %s°, 耗时: %v)",
		filepath.Base(filePath), dirStr, time.Since(start),
	)
	return nil
}

// WriteCameraPerspectiveDirectly 🌟 核心调度器：自动探测资产组并按照 SidecarPolicy 调度写入完整 3D 摄影视角
// 包含真北朝向、俯仰角、横滚角、视锥视距与溯源指纹
func WriteCameraPerspectiveDirectly(
	runner CommandRunner, primaryPath string, payload CameraPerspectivePayload, policy domain.SidecarPolicy,
) (finalErr error) {
	start := time.Now()
	if primaryPath == "" {
		return errors.New("主文件路径不能为空")
	}
	if _, err := os.Stat(primaryPath); err != nil {
		return fmt.Errorf("主文件不存在: %w", err)
	}

	normPolicy := domain.NormalizePolicy(string(policy))
	logger.Infof(
		"调度器-视角写入", "启动 3D 摄影视角调度写入: %s (策略: %s, 朝向: %.2f°, 视距: %.1fm)",
		filepath.Base(primaryPath), normPolicy, payload.Heading, payload.ViewDistance,
	)

	defer func() {
		if finalErr != nil {
			logger.Errorf(
				"调度器-视角写入", "视角调度写入失败: %s -> %v (耗时: %v)",
				filepath.Base(primaryPath), finalErr, time.Since(start),
			)
		} else {
			logger.Successf(
				"调度器-视角写入", "视角调度写入完成: %s (耗时: %v)",
				filepath.Base(primaryPath), time.Since(start),
			)
		}
	}()

	asset := FindAssetGroupForPath(primaryPath)

	switch normPolicy {
	case domain.PolicySidecarOnly:
		// 纯侧车模式：RAW/JPG 100% 只读，仅写 .xmp 侧车
		xmpPath := asset.SidecarPathFor(asset.PrimaryPath())
		if asset.HasXMP() {
			xmpPath = asset.XMPPath
		}
		if err := WritePerspectiveToXMP(runner, xmpPath, payload); err != nil {
			finalErr = err
			return finalErr
		}
		finalErr = VerifyPerspectiveTags(runner, xmpPath)
		return finalErr

	case domain.PolicyEmbedOnly:
		// 纯原图内嵌：只写原图，不触碰 XMP
		primary := asset.PrimaryPath()
		if err := WritePerspectiveToMedia(runner, primary, payload); err != nil {
			finalErr = err
			return finalErr
		}
		finalErr = VerifyPerspectiveTags(runner, primary)
		return finalErr

	case domain.PolicyEmbedAndSidecar:
		// 双写同步：原图内嵌 + XMP 侧车同步
		primary := asset.PrimaryPath()
		if err := WritePerspectiveToMedia(runner, primary, payload); err != nil {
			finalErr = err
			return finalErr
		}
		if err := VerifyPerspectiveTags(runner, primary); err != nil {
			finalErr = err
			return finalErr
		}
		xmpPath := asset.SidecarPathFor(primary)
		if asset.HasXMP() {
			xmpPath = asset.XMPPath
		}
		if err := WritePerspectiveToXMP(runner, xmpPath, payload); err != nil {
			finalErr = err
			return finalErr
		}
		finalErr = VerifyPerspectiveTags(runner, xmpPath)
		return finalErr

	default:
		// smart 模式（默认/推荐）：
		// - RAW: 写入原图 EXIF（第二层修正事实）+ 同步 XMP 侧车
		// - JPG: 直接内嵌
		primary := asset.PrimaryPath()
		if err := WritePerspectiveToMedia(runner, primary, payload); err != nil {
			finalErr = err
			return finalErr
		}
		if err := VerifyPerspectiveTags(runner, primary); err != nil {
			finalErr = err
			return finalErr
		}
		// 同步伴随 JPG（如有）
		if asset.HasJPG() && asset.JPGPath != primary {
			if err := WritePerspectiveToMedia(runner, asset.JPGPath, payload); err != nil {
				finalErr = fmt.Errorf("同步写入伴随 JPG 视角失败: %w", err)
				return finalErr
			}
		}
		// 同步 XMP 侧车（如有）
		xmpPath := ""
		if asset.HasXMP() {
			xmpPath = asset.XMPPath
		} else {
			candidate := asset.SidecarPathFor(primary)
			if _, err := os.Stat(candidate); err == nil {
				xmpPath = candidate
			}
		}
		if xmpPath != "" {
			if err := WritePerspectiveToXMP(runner, xmpPath, payload); err != nil {
				finalErr = fmt.Errorf("同步写入 XMP 侧车视角失败: %w", err)
				return finalErr
			}
		}
		return nil
	}
}

// WriteImgDirectionDirectly 适配器：向后兼容，封装为 WriteCameraPerspectiveDirectly
func WriteImgDirectionDirectly(
	runner CommandRunner, primaryPath string, degreesTrueNorth float64, policy domain.SidecarPolicy,
) error {
	payload := CameraPerspectivePayload{
		Heading: degreesTrueNorth,
		Provenance: domain.GPSProvenance{
			Processor: "ManualHeading",
		},
	}
	return WriteCameraPerspectiveDirectly(runner, primaryPath, payload, policy)
}

// ==========================================
// 2. 逆地理编码地名元数据写入与同步 (Cap 2)
// ==========================================

// ReadLocationTags 读取目标照片或 XMP 侧车文件中的现有关键字和分层标签 (用于增量清洗与去重)
func ReadLocationTags(runner CommandRunner, filePath string) (domain.ExistingTags, error) {
	start := time.Now()
	if filePath == "" {
		return domain.ExistingTags{}, nil
	}
	if _, err := os.Stat(filePath); err != nil {
		return domain.ExistingTags{}, nil
	}

	out, err := runner.CombinedOutput(
		"exiftool", "-j", "-q", "-m",
		"-XMP-lr:HierarchicalSubject",
		"-XMP-dc:subject",
		"-IPTC:Keywords",
		filePath,
	)
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return domain.ExistingTags{}, nil
	}

	var records []map[string]any
	if err := json.Unmarshal(out, &records); err != nil || len(records) == 0 {
		return domain.ExistingTags{}, nil
	}

	dict := records[0]
	parseSlice := func(keys ...string) []string {
		for _, k := range keys {
			if v, ok := dict[k]; ok {
				switch val := v.(type) {
				case string:
					if s := strings.TrimSpace(val); s != "" {
						return []string{s}
					}
				case []any:
					var items []string
					for _, it := range val {
						if str, ok := it.(string); ok {
							if s := strings.TrimSpace(str); s != "" {
								items = append(items, s)
							}
						}
					}
					return items
				case []string:
					return val
				}
			}
		}
		return nil
	}

	tags := domain.ExistingTags{
		HierarchicalSubject: parseSlice("HierarchicalSubject", "XMP-lr:HierarchicalSubject"),
		Subject:             parseSlice("Subject", "XMP-dc:Subject", "subject"),
		Keywords:            parseSlice("Keywords", "IPTC:Keywords"),
	}

	logger.Debugf(
		"ExifTool读取-标签", "成功提取现有标签: %s (分层标签: %d 个, 主题: %d 个, 耗时: %v)",
		filepath.Base(filePath), len(tags.HierarchicalSubject), len(tags.Subject), time.Since(start),
	)
	return tags, nil
}

// BuildLocationArgsWithTags 根据清洗后的标签集合与位置元数据构造原子写入指令 (原子清空并全量重写，绝不使用 +=)
func BuildLocationArgsWithTags(loc domain.LocationInfo, tags domain.CleanedLocationTags) []string {
	var args []string

	// 1. 基础国省市行政区划 (XMP-photoshop & IPTC IIM & IPTC Extension)
	if loc.Country != "" {
		args = append(
			args,
			fmt.Sprintf("-XMP-photoshop:Country=%s", loc.Country),
			fmt.Sprintf("-IPTC:Country-PrimaryLocationName=%s", loc.Country),
			fmt.Sprintf("-XMP-iptcExt:LocationCreatedCountryName=%s", loc.Country),
			fmt.Sprintf("-XMP-iptcExt:LocationShownCountryName=%s", loc.Country),
		)
	}
	if loc.CountryCode != "" {
		alpha2 := domain.ToAlpha2(loc.CountryCode)
		alpha3 := domain.ToAlpha3(loc.CountryCode)
		args = append(
			args,
			fmt.Sprintf("-XMP-iptcCore:CountryCode=%s", alpha2),
			fmt.Sprintf("-IPTC:Country-PrimaryLocationCode=%s", alpha3),
			fmt.Sprintf("-XMP-iptcExt:LocationCreatedCountryCode=%s", alpha2),
			fmt.Sprintf("-XMP-iptcExt:LocationShownCountryCode=%s", alpha2),
		)
	}
	if loc.Province != "" {
		args = append(
			args,
			fmt.Sprintf("-XMP-photoshop:State=%s", loc.Province),
			fmt.Sprintf("-IPTC:Province-State=%s", loc.Province),
			fmt.Sprintf("-XMP-iptcExt:LocationCreatedProvinceState=%s", loc.Province),
			fmt.Sprintf("-XMP-iptcExt:LocationShownProvinceState=%s", loc.Province),
		)
	}
	if loc.City != "" {
		args = append(
			args,
			fmt.Sprintf("-XMP-photoshop:City=%s", loc.City),
			fmt.Sprintf("-IPTC:City=%s", loc.City),
			fmt.Sprintf("-XMP-iptcExt:LocationCreatedCity=%s", loc.City),
			fmt.Sprintf("-XMP-iptcExt:LocationShownCity=%s", loc.City),
		)
	}
	if loc.District != "" {
		args = append(
			args,
			fmt.Sprintf("-XMP-iptcCore:Location=%s", loc.District),
			fmt.Sprintf("-IPTC:Sub-location=%s", loc.District),
			fmt.Sprintf("-XMP-iptcExt:LocationCreatedSublocation=%s", loc.District),
			fmt.Sprintf("-XMP-iptcExt:LocationShownSublocation=%s", loc.District),
		)
	} else {
		// 显式重置/置空区县字段，根除旧地名 Sublocation 残留 (避免缝合怪)
		args = append(
			args,
			"-XMP-iptcCore:Location=",
			"-IPTC:Sub-location=",
			"-XMP-iptcExt:LocationCreatedSublocation=",
			"-XMP-iptcExt:LocationShownSublocation=",
		)
	}

	// 2. 专业分层关键词树 (HierarchicalSubject) 与关键字列表 (Subject / Keywords)
	// 彻底废除 +=，采用原子置空 + 全量重写
	args = append(args, "-XMP-lr:HierarchicalSubject=")
	for _, tree := range tags.HierarchicalSubject {
		args = append(args, fmt.Sprintf("-XMP-lr:HierarchicalSubject=%s", tree))
	}

	args = append(args, "-XMP-dc:subject=")
	for _, sub := range tags.Subject {
		args = append(args, fmt.Sprintf("-XMP-dc:subject=%s", sub))
	}

	args = append(args, "-IPTC:Keywords=")
	for _, kw := range tags.Keywords {
		args = append(args, fmt.Sprintf("-IPTC:Keywords=%s", kw))
	}

	return args
}

// BuildLocationArgs 向后兼容适配器：默认以全新纯净状态构造写入参数
func BuildLocationArgs(loc domain.LocationInfo) []string {
	tags := domain.CleanAndMergeLocationTags(domain.ExistingTags{}, loc)
	return BuildLocationArgsWithTags(loc, tags)
}

// WriteLocationToMedia 写入逆地理编码地名标签到照片媒体文件（内嵌模式，先读出旧标签清洗合并再原子写入）
func WriteLocationToMedia(runner CommandRunner, filePath string, loc domain.LocationInfo) error {
	start := time.Now()
	if loc.City == "" && loc.Province == "" && loc.Country == "" && loc.District == "" {
		return nil
	}

	logger.Infof(
		"ExifTool写入-地名", "写入媒体文件地名: %s (%s)",
		filepath.Base(filePath), loc.FormatSummary(),
	)

	existing, _ := ReadLocationTags(runner, filePath)
	cleanedTags := domain.CleanAndMergeLocationTags(existing, loc)

	args := []string{
		"-overwrite_original",
		"-P",
		"-charset", "UTF8",
		"-codedcharacterset=utf8",
	}
	args = append(args, BuildLocationArgsWithTags(loc, cleanedTags)...)
	args = append(args, filePath)

	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		wErr := fmt.Errorf("写入地理位置信息失败: %w", err)
		logger.Errorf(
			"ExifTool写入-地名", "写入媒体地名失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(filePath), wErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return wErr
	}
	logger.Successf(
		"ExifTool写入-地名", "写入媒体地名成功: %s (分层标签: %d 个, 耗时: %v)",
		filepath.Base(filePath), len(cleanedTags.HierarchicalSubject), time.Since(start),
	)
	return nil
}

// WriteLocationToXMP 🌟 写入逆地理编码地名标签到 XMP 侧车文件（先读出旧标签清洗合并再原子写入）
func WriteLocationToXMP(runner CommandRunner, xmpPath string, loc domain.LocationInfo) error {
	start := time.Now()
	if loc.City == "" && loc.Province == "" && loc.Country == "" && loc.District == "" {
		return nil
	}

	logger.Infof(
		"ExifTool写入-地名", "写入 XMP 侧车地名: %s (%s)",
		filepath.Base(xmpPath), loc.FormatSummary(),
	)

	existing, _ := ReadLocationTags(runner, xmpPath)
	cleanedTags := domain.CleanAndMergeLocationTags(existing, loc)

	args := []string{
		"-overwrite_original",
		"-P",
		"-charset", "UTF8",
		"-codedcharacterset=utf8",
	}
	args = append(args, BuildLocationArgsWithTags(loc, cleanedTags)...)
	args = append(args, xmpPath)

	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		wErr := fmt.Errorf("写入地理位置信息到 XMP 侧车文件失败: %w", err)
		logger.Errorf(
			"ExifTool写入-地名", "写入 XMP 侧车地名失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(xmpPath), wErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return wErr
	}
	logger.Successf(
		"ExifTool写入-地名", "写入 XMP 侧车地名成功: %s (分层标签: %d 个, 耗时: %v)",
		filepath.Base(xmpPath), len(cleanedTags.HierarchicalSubject), time.Since(start),
	)
	return nil
}

// SyncLocationToJPG 将 RAW 中的地名元数据（IPTC/XMP-photoshop/IPTC-Ext/HierarchicalSubject）同步到 JPG 文件
func SyncLocationToJPG(runner CommandRunner, sourceRaw, targetJPG string) error {
	start := time.Now()
	logger.Infof(
		"ExifTool同步-地名", "从 RAW 同步地名至伴随 JPG: %s -> %s",
		filepath.Base(sourceRaw), filepath.Base(targetJPG),
	)

	out, err := runner.CombinedOutput(
		"exiftool", "-overwrite_original", "-P",
		"-charset", "UTF8",
		"-codedcharacterset=utf8",
		"-TagsFromFile", sourceRaw,
		"-IPTC:all",
		"-XMP-photoshop:all",
		"-XMP-iptcCore:all",
		"-XMP-iptcExt:all",
		"-XMP-lr:all",
		"-XMP-dc:all",
		targetJPG,
	)
	if err != nil {
		sErr := fmt.Errorf("同步地名元数据到 JPG 失败：%w", err)
		logger.Errorf(
			"ExifTool同步-地名", "同步地名到 JPG 失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(targetJPG), sErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return sErr
	}
	logger.Successf(
		"ExifTool同步-地名", "同步地名到 JPG 成功: %s (耗时: %v)",
		filepath.Base(targetJPG), time.Since(start),
	)
	return nil
}

// SyncLocationToXMP 将 RAW 中的地名元数据映射写入到伴随的 XMP 侧车文件
func SyncLocationToXMP(runner CommandRunner, sourceRaw, targetXMP string) error {
	start := time.Now()
	logger.Infof(
		"ExifTool同步-地名", "从 RAW 同步地名至伴随 XMP: %s -> %s",
		filepath.Base(sourceRaw), filepath.Base(targetXMP),
	)

	args := []string{
		"-overwrite_original",
		"-P",
		"-charset", "UTF8",
		"-TagsFromFile", sourceRaw,
		"-XMP-photoshop:Country<XMP-photoshop:Country",
		"-XMP-photoshop:State<XMP-photoshop:State",
		"-XMP-photoshop:City<XMP-photoshop:City",
		"-XMP-iptcCore:CountryCode<XMP-iptcCore:CountryCode",
		"-XMP-iptcCore:Location<XMP-iptcCore:Location",
		"-XMP-iptcExt:LocationCreatedCountryName<XMP-iptcExt:LocationCreatedCountryName",
		"-XMP-iptcExt:LocationCreatedCountryCode<XMP-iptcExt:LocationCreatedCountryCode",
		"-XMP-iptcExt:LocationCreatedProvinceState<XMP-iptcExt:LocationCreatedProvinceState",
		"-XMP-iptcExt:LocationCreatedCity<XMP-iptcExt:LocationCreatedCity",
		"-XMP-iptcExt:LocationCreatedSublocation<XMP-iptcExt:LocationCreatedSublocation",
		"-XMP-iptcExt:LocationShownCountryName<XMP-iptcExt:LocationShownCountryName",
		"-XMP-iptcExt:LocationShownCountryCode<XMP-iptcExt:LocationShownCountryCode",
		"-XMP-iptcExt:LocationShownProvinceState<XMP-iptcExt:LocationShownProvinceState",
		"-XMP-iptcExt:LocationShownCity<XMP-iptcExt:LocationShownCity",
		"-XMP-iptcExt:LocationShownSublocation<XMP-iptcExt:LocationShownSublocation",
		"-XMP-lr:HierarchicalSubject<XMP-lr:HierarchicalSubject",
		"-XMP-dc:subject<XMP-dc:subject",
		targetXMP,
	}
	out, err := runner.CombinedOutput("exiftool", args...)
	if err != nil {
		sErr := fmt.Errorf("同步地名元数据到 XMP 失败：%w", err)
		logger.Errorf(
			"ExifTool同步-地名", "同步地名到 XMP 失败: %s -> %v (输出: %s, 耗时: %v)",
			filepath.Base(targetXMP), sErr, strings.TrimSpace(string(out)), time.Since(start),
		)
		return sErr
	}
	logger.Successf(
		"ExifTool同步-地名", "同步地名到 XMP 成功: %s (耗时: %v)",
		filepath.Base(targetXMP), time.Since(start),
	)
	return nil
}

// ==========================================
// 3. 坐标解析与格式转换工具
// ==========================================

var (
	// 匹配 "39 deg 54' 15.00\" N, 116 deg 23' 30.00\" E" 或 "39 deg 54' 15.00\" N 116 deg 23' 30.00\" E"
	dmsRegex = regexp.MustCompile(`(\d+)\s*deg\s*(\d+)'\s*([\d.]+)"?\s*([NSEWnsew])`)
	// 匹配 "39.9042 N, 116.3917 E"
	decHemiRegex = regexp.MustCompile(`([\d.]+)\s*([NSEWnsew])`)
)

// ParseCoordinates 解析 GPSPosition 字符串为浮点数经纬度 (lat, lon)
func ParseCoordinates(posStr string) (lat, lon float64, err error) {
	clean := strings.TrimSpace(posStr)
	if clean == "" {
		return 0, 0, errors.New("GPSPosition 字符串为空")
	}

	// 1. 尝试 DMS 匹配
	dmsMatches := dmsRegex.FindAllStringSubmatch(clean, -1)
	if len(dmsMatches) >= 2 {
		lat, err1 := dmsToDecimal(dmsMatches[0][1], dmsMatches[0][2], dmsMatches[0][3], dmsMatches[0][4])
		lon, err2 := dmsToDecimal(dmsMatches[1][1], dmsMatches[1][2], dmsMatches[1][3], dmsMatches[1][4])
		if err1 == nil && err2 == nil {
			return lat, lon, nil
		}
	}

	// 2. 尝试纯十进制+方向匹配 (如 "39.9042 N, 116.3917 E")
	decMatches := decHemiRegex.FindAllStringSubmatch(clean, -1)
	if len(decMatches) >= 2 {
		lat, err1 := decHemiToDecimal(decMatches[0][1], decMatches[0][2])
		lon, err2 := decHemiToDecimal(decMatches[1][1], decMatches[1][2])
		if err1 == nil && err2 == nil {
			return lat, lon, nil
		}
	}

	// 3. 尝试逗号或空格分隔的纯浮点数 (如 "39.9042, 116.3917")
	parts := strings.FieldsFunc(
		clean, func(r rune) bool {
			return r == ',' || r == ' ' || r == '\t'
		},
	)
	var cleanParts []string
	for _, p := range parts {
		if p != "" {
			cleanParts = append(cleanParts, p)
		}
	}
	if len(cleanParts) >= 2 {
		latVal, err1 := strconv.ParseFloat(cleanParts[0], 64)
		lonVal, err2 := strconv.ParseFloat(cleanParts[1], 64)
		if err1 == nil && err2 == nil {
			return latVal, lonVal, nil
		}
	}

	return 0, 0, fmt.Errorf("无法识别的 GPSPosition 格式: %s", posStr)
}

func dmsToDecimal(degStr, minStr, secStr, hemi string) (float64, error) {
	deg, err1 := strconv.ParseFloat(degStr, 64)
	min, err2 := strconv.ParseFloat(minStr, 64)
	sec, err3 := strconv.ParseFloat(secStr, 64)
	if err1 != nil || err2 != nil || err3 != nil {
		return 0, errors.New("无效的 DMS 数值")
	}

	dec := deg + (min / 60.0) + (sec / 3600.0)
	hemi = strings.ToUpper(hemi)
	if hemi == "S" || hemi == "W" {
		dec = -dec
	}
	return dec, nil
}

func decHemiToDecimal(valStr, hemi string) (float64, error) {
	val, err := strconv.ParseFloat(valStr, 64)
	if err != nil {
		return 0, err
	}
	hemi = strings.ToUpper(hemi)
	if hemi == "S" || hemi == "W" {
		val = -val
	}
	return val, nil
}

// ==========================================
// 4. 完整照片元数据深度检查 (用于 UI 检查器与调试)
// ==========================================

type DetailedPhotoMetadata struct {
	FilePath                string        `json:"file_path"`
	FileName                string        `json:"file_name"`
	FileSize                string        `json:"file_size"`
	FileModifyDate          string        `json:"file_modify_date"`
	CameraMake              string        `json:"camera_make,omitempty"`
	CameraModel             string        `json:"camera_model,omitempty"`
	LensModel               string        `json:"lens_model,omitempty"`
	DateTimeOriginal        string        `json:"date_time_original,omitempty"`
	ExposureTime            string        `json:"exposure_time,omitempty"`
	FNumber                 string        `json:"f_number,omitempty"`
	ISO                     string        `json:"iso,omitempty"`
	FocalLength             string        `json:"focal_length,omitempty"`
	ExposureProgram         string        `json:"exposure_program,omitempty"`
	Latitude                *float64      `json:"latitude,omitempty"`
	Longitude               *float64      `json:"longitude,omitempty"`
	Altitude                *float64      `json:"altitude,omitempty"`
	GPSPosition             string        `json:"gps_position,omitempty"`
	GPSImgDirection         *float64      `json:"gps_img_direction,omitempty"`
	GPSImgDirectionRef      string        `json:"gps_img_direction_ref,omitempty"`
	FocalLengthIn35mmFormat *float64      `json:"focal_length_in_35mm_format,omitempty"`
	YawAngle                *float64      `json:"yaw_angle,omitempty"`
	PitchAngle              *float64      `json:"pitch_angle,omitempty"`
	RollAngle               *float64      `json:"roll_angle,omitempty"`
	FOV                     string        `json:"fov,omitempty"`
	FocusDistance           string        `json:"focus_distance,omitempty"`
	ViewDistance            *float64      `json:"view_distance,omitempty"`
	Country                 string        `json:"country,omitempty"`
	Province                string        `json:"province,omitempty"`
	City                    string        `json:"city,omitempty"`
	District                string        `json:"district,omitempty"`
	Title                   string        `json:"title,omitempty"`
	Description             string        `json:"description,omitempty"`
	GPSSource               string        `json:"gps_source,omitempty"`
	GPSMatchMethod          string        `json:"gps_match_method,omitempty"`
	InterpolateWindow       string        `json:"interpolate_window,omitempty"`
	Processor               string        `json:"processor,omitempty"`
	ProcessedDate           string        `json:"processed_date,omitempty"`
	GeocodeSource           string        `json:"geocode_source,omitempty"`
	SidecarPath             string        `json:"sidecar_path,omitempty"`
	RawTags                 []ExifTagItem `json:"raw_tags,omitempty"`
}

type ExifTagItem struct {
	Group string `json:"group"`
	Tag   string `json:"tag"`
	Value string `json:"value"`
}

// FindCompanionXMP 探测指定照片文件同级目录下是否存在配套的 XMP 侧车文件
func FindCompanionXMP(path string) string {
	ext := filepath.Ext(path)
	baseNoExt := strings.TrimSuffix(path, ext)
	candidates := []string{
		path + ".xmp",
		path + ".XMP",
		baseNoExt + ".xmp",
		baseNoExt + ".XMP",
		baseNoExt + strings.ToLower(ext) + ".xmp",
		baseNoExt + strings.ToUpper(ext) + ".xmp",
	}
	for _, c := range candidates {
		if c != path {
			if _, err := os.Stat(c); err == nil {
				return c
			}
		}
	}
	return ""
}

// InspectPhotoMetadata 深度检查单张照片及其配套 XMP 侧车的全部 EXIF / IPTC / XMP 元数据与溯源指纹
func InspectPhotoMetadata(runner CommandRunner, path string) (*DetailedPhotoMetadata, error) {
	start := time.Now()
	paths := []string{path}
	sidecarPath := FindCompanionXMP(path)
	if sidecarPath != "" {
		paths = append(paths, sidecarPath)
	}

	args := append([]string{"-m", "-q", "-j", "-G1", "-a", "-s", "-c", "%.6f"}, paths...)
	output, err := runner.CombinedOutput("exiftool", args...)
	if err != nil && len(output) == 0 {
		iErr := fmt.Errorf("exiftool 检查元数据失败: %w", err)
		logger.Errorf(
			"ExifTool读取-探针", "元数据探针执行失败: %s -> %v (耗时: %v)",
			filepath.Base(path), iErr, time.Since(start),
		)
		return nil, iErr
	}

	cleanOutput := bytes.TrimSpace(output)
	if len(cleanOutput) == 0 {
		iErr := errors.New("exiftool 未返回任何元数据")
		logger.Warnf(
			"ExifTool读取-探针", "元数据探针未返回数据: %s (耗时: %v)",
			filepath.Base(path), time.Since(start),
		)
		return nil, iErr
	}

	// 容错剥离前缀
	jsonStart := bytes.IndexByte(cleanOutput, '[')
	if jsonStart >= 0 {
		if end := bytes.LastIndexByte(cleanOutput, ']'); end > jsonStart {
			cleanOutput = cleanOutput[jsonStart : end+1]
		}
	}

	var records []map[string]any
	if err := json.Unmarshal(cleanOutput, &records); err != nil || len(records) == 0 {
		return nil, fmt.Errorf("解析 exiftool 检查输出失败: %w (原始: %s)", err, string(cleanOutput))
	}

	dict := records[0]
	var dictXMP map[string]any
	if len(records) > 1 {
		dictXMP = records[1]
	}

	strValFrom := func(targetDict map[string]any, keys ...string) string {
		if targetDict == nil {
			return ""
		}
		for _, k := range keys {
			for dk, dv := range targetDict {
				tagPart := dk
				if _, after, found := strings.Cut(dk, ":"); found {
					tagPart = after
				}
				if strings.EqualFold(dk, k) || strings.EqualFold(tagPart, k) {
					s := fmt.Sprintf("%v", dv)
					s = strings.TrimSpace(s)
					if s != "" && s != "<nil>" && s != "0" && s != "undef" && s != "-" {
						return s
					}
				}
			}
		}
		return ""
	}

	strVal := func(keys ...string) string {
		return strValFrom(dict, keys...)
	}

	floatValFrom := func(targetDict map[string]any, keys ...string) *float64 {
		if targetDict == nil {
			return nil
		}
		for _, k := range keys {
			for dk, dv := range targetDict {
				tagPart := dk
				if _, after, found := strings.Cut(dk, ":"); found {
					tagPart = after
				}
				if strings.EqualFold(dk, k) || strings.EqualFold(tagPart, k) {
					switch v := dv.(type) {
					case float64:
						return &v
					case float32:
						fv := float64(v)
						return &fv
					case int:
						fv := float64(v)
						return &fv
					case int64:
						fv := float64(v)
						return &fv
					case string:
						s := strings.TrimSpace(v)
						s = strings.TrimSuffix(s, " Above Sea Level")
						s = strings.TrimSuffix(s, " Below Sea Level")
						s = strings.TrimSuffix(s, " m")
						s = strings.TrimSpace(s)
						isNeg := strings.HasSuffix(strings.ToUpper(s), "S") || strings.HasSuffix(
							strings.ToUpper(s), "W",
						)
						s = strings.TrimSuffix(s, " N")
						s = strings.TrimSuffix(s, " S")
						s = strings.TrimSuffix(s, " E")
						s = strings.TrimSuffix(s, " W")
						s = strings.TrimSpace(s)
						if fv, err := strconv.ParseFloat(s, 64); err == nil {
							if isNeg && fv > 0 {
								fv = -fv
							}
							return &fv
						}
					}
				}
			}
		}
		return nil
	}

	floatVal := func(keys ...string) *float64 {
		return floatValFrom(dict, keys...)
	}

	makeStr := strVal("EXIF:Make", "Make", "QuickTime:Make")
	modelStr := strVal("EXIF:Model", "Model", "QuickTime:Model")
	lensStr := strVal(
		"EXIF:LensModel", "XMP:LensModel", "MakerNotes:Lens", "MakerNotes:LensType", "LensModel", "Composite:LensSpec",
		"Composite:LensID", "Lens",
	)
	dateStr := strVal("EXIF:DateTimeOriginal", "XMP:DateTimeOriginal", "QuickTime:CreateDate", "DateTimeOriginal")
	expStr := strVal("EXIF:ExposureTime", "Composite:ShutterSpeed", "ExposureTime", "ShutterSpeed")
	fnStr := strVal("EXIF:FNumber", "Composite:Aperture", "FNumber", "ApertureValue", "Aperture")
	isoStr := strVal("EXIF:ISO", "EXIF:ISOSpeedRatings", "MakerNotes:ISO", "ISO")
	focalStr := strVal("EXIF:FocalLength", "Composite:FocalLength35efl", "EXIF:FocalLengthIn35mmFormat", "FocalLength")
	progStr := strVal("EXIF:ExposureProgram", "ExposureProgram")

	latVal := floatVal("GPS:GPSLatitude", "Composite:GPSLatitude", "GPSLatitude")
	lonVal := floatVal("GPS:GPSLongitude", "Composite:GPSLongitude", "GPSLongitude")
	altVal := floatVal("GPS:GPSAltitude", "Composite:GPSAltitude", "GPSAltitude")
	posStr := strVal("Composite:GPSPosition", "GPS:GPSPosition", "GPSPosition")

	// 若主文件无 GPS，从 XMP 侧车补全
	if (latVal == nil || lonVal == nil) && dictXMP != nil {
		latVal = floatValFrom(dictXMP, "XMP:GPSLatitude", "Composite:GPSLatitude", "GPSLatitude")
		lonVal = floatValFrom(dictXMP, "XMP:GPSLongitude", "Composite:GPSLongitude", "GPSLongitude")
		altVal = floatValFrom(dictXMP, "XMP:GPSAltitude", "Composite:GPSAltitude", "GPSAltitude")
		posStr = strValFrom(dictXMP, "Composite:GPSPosition", "GPSPosition")
	}

	// 如果经纬度解析为 nil 但有 GPSPosition 字符串，尝试反解
	if (latVal == nil || lonVal == nil) && posStr != "" {
		if lat, lon, err := ParseCoordinates(posStr); err == nil {
			latVal = &lat
			lonVal = &lon
		}
	}

	imgDirVal := floatVal(
		"GPS:GPSImgDirection", "Composite:GPSImgDirection", "GPSImgDirection", "XMP:GPSImgDirection",
		"GPS:GPSDestBearing", "Composite:GPSDestBearing", "GPSDestBearing", "XMP:GPSDestBearing",
	)
	imgDirRefStr := strVal(
		"GPS:GPSImgDirectionRef", "GPSImgDirectionRef", "XMP:GPSImgDirectionRef",
		"GPS:GPSDestBearingRef", "GPSDestBearingRef", "XMP:GPSDestBearingRef",
	)
	focal35mmVal := floatVal("EXIF:FocalLengthIn35mmFormat", "Composite:FocalLength35efl", "FocalLengthIn35mmFormat")
	yawVal := floatVal("MakerNotes:YawAngle", "XMP-Camera:Yaw", "XMP-photools:Yaw", "YawAngle", "Yaw")
	pitchVal := floatVal("MakerNotes:PitchAngle", "XMP-Camera:Pitch", "XMP-photools:Pitch", "PitchAngle", "Pitch")
	rollVal := floatVal("MakerNotes:RollAngle", "XMP-Camera:Roll", "XMP-photools:Roll", "RollAngle", "Roll")
	fovStr := strVal("Composite:FOV", "FOV")
	focusDistStr := strVal("MakerNotes:FocusDistance", "FocusDistance")
	viewDistVal := floatVal("XMP-photools:ViewDistance", "ViewDistance")

	if dictXMP != nil {
		if yawVal == nil {
			yawVal = floatValFrom(dictXMP, "XMP-Camera:Yaw", "XMP-photools:Yaw", "YawAngle", "Yaw")
		}
		if pitchVal == nil {
			pitchVal = floatValFrom(dictXMP, "XMP-Camera:Pitch", "XMP-photools:Pitch", "PitchAngle", "Pitch")
		}
		if rollVal == nil {
			rollVal = floatValFrom(dictXMP, "XMP-Camera:Roll", "XMP-photools:Roll", "RollAngle", "Roll")
		}
		if viewDistVal == nil {
			viewDistVal = floatValFrom(dictXMP, "XMP-photools:ViewDistance", "ViewDistance")
		}
	}

	if imgDirVal == nil && dictXMP != nil {
		imgDirVal = floatValFrom(
			dictXMP,
			"XMP:GPSImgDirection", "GPS:GPSImgDirection", "GPSImgDirection",
			"XMP:GPSDestBearing", "GPS:GPSDestBearing", "GPSDestBearing",
		)
		if imgDirRefStr == "" {
			imgDirRefStr = strValFrom(
				dictXMP,
				"XMP:GPSImgDirectionRef", "GPS:GPSImgDirectionRef", "GPSImgDirectionRef",
				"XMP:GPSDestBearingRef", "GPS:GPSDestBearingRef", "GPSDestBearingRef",
			)
		}
	}

	countryStr := strVal("XMP:Country", "IPTC:Country-PrimaryLocationName", "Country")
	provStr := strVal("XMP:State", "IPTC:Province-State", "State", "Province")
	cityStr := strVal("XMP:City", "IPTC:City", "City")
	distStr := strVal("XMP:Location", "IPTC:Sub-location", "Sublocation", "District")
	titleStr := strVal("XMP:Title", "IPTC:ObjectName", "Title")
	descStr := strVal("XMP:Description", "IPTC:Caption-Abstract", "Description")

	geocodeSource := ""
	if countryStr != "" || provStr != "" || cityStr != "" || distStr != "" {
		geocodeSource = "embedded"
	}

	// 联合解析 XMP 侧车中的中文地名与 IPTC Extension
	if dictXMP != nil {
		xCountry := strValFrom(dictXMP, "XMP-photoshop:Country", "XMP:Country", "LocationCreatedCountryName", "Country")
		xProv := strValFrom(dictXMP, "XMP-photoshop:State", "XMP:State", "LocationCreatedProvinceState", "State")
		xCity := strValFrom(dictXMP, "XMP-photoshop:City", "XMP:City", "LocationCreatedCity", "City")
		xDist := strValFrom(dictXMP, "XMP-iptcCore:Location", "XMP:Location", "LocationCreatedSublocation", "Location")

		if xCountry != "" || xProv != "" || xCity != "" || xDist != "" {
			if countryStr == "" {
				countryStr = xCountry
			}
			if provStr == "" {
				provStr = xProv
			}
			if cityStr == "" {
				cityStr = xCity
			}
			if distStr == "" {
				distStr = xDist
			}
			geocodeSource = "xmp"
		}
	}

	// 提取 Photools 专属溯源与审计指纹 (Provenance)
	gpsSource := strValFrom(dictXMP, "XMP-photools:GPSSource", "GPSSource")
	if gpsSource == "" {
		gpsSource = strVal("XMP-photools:GPSSource", "GPSSource")
	}
	gpsMatchMethod := strValFrom(dictXMP, "XMP-photools:GPSMatchMethod", "GPSMatchMethod")
	if gpsMatchMethod == "" {
		gpsMatchMethod = strVal("XMP-photools:GPSMatchMethod", "GPSMatchMethod")
	}
	interpolateWindow := strValFrom(dictXMP, "XMP-photools:InterpolateWindow", "InterpolateWindow")
	if interpolateWindow == "" {
		interpolateWindow = strVal("XMP-photools:InterpolateWindow", "InterpolateWindow")
	}
	processor := strValFrom(dictXMP, "XMP-photools:Processor", "Processor", "XMP:CreatorTool", "CreatorTool")
	if processor == "" {
		processor = strVal("XMP-photools:Processor", "Processor", "XMP:CreatorTool", "CreatorTool")
	}
	processedDate := strValFrom(
		dictXMP, "XMP-photools:ProcessedDate", "ProcessedDate", "XMP:MetadataDate", "MetadataDate",
	)
	if processedDate == "" {
		processedDate = strVal("XMP-photools:ProcessedDate", "ProcessedDate", "XMP:MetadataDate", "MetadataDate")
	}

	fileSizeStr := strVal("File:FileSize", "FileSize")
	modDateStr := strVal("File:FileModifyDate", "FileModifyDate")

	var rawTags []ExifTagItem
	seenTags := make(map[string]bool)

	// 主文件标签
	for k, v := range dict {
		if k == "SourceFile" {
			continue
		}
		parts := strings.SplitN(k, ":", 2)
		group := "General"
		tag := k
		if len(parts) == 2 {
			group = parts[0]
			tag = parts[1]
		}
		tagKey := group + ":" + tag
		seenTags[tagKey] = true
		rawTags = append(
			rawTags, ExifTagItem{
				Group: group,
				Tag:   tag,
				Value: fmt.Sprintf("%v", v),
			},
		)
	}

	// 联合装入配套 XMP 侧车文件中的所有标签
	if dictXMP != nil {
		for k, v := range dictXMP {
			if k == "SourceFile" {
				continue
			}
			parts := strings.SplitN(k, ":", 2)
			group := "XMP 侧车"
			tag := k
			if len(parts) == 2 {
				group = parts[0] + " (XMP侧车)"
				tag = parts[1]
			}
			tagKey := group + ":" + tag
			if !seenTags[tagKey] {
				seenTags[tagKey] = true
				rawTags = append(
					rawTags, ExifTagItem{
						Group: group,
						Tag:   tag,
						Value: fmt.Sprintf("%v", v),
					},
				)
			}
		}
	}

	slices.SortFunc(
		rawTags, func(a, b ExifTagItem) int {
			if c := cmp.Compare(a.Group, b.Group); c != 0 {
				return c
			}
			return cmp.Compare(a.Tag, b.Tag)
		},
	)

	result := &DetailedPhotoMetadata{
		FilePath:                path,
		FileName:                filepath.Base(path),
		FileSize:                fileSizeStr,
		FileModifyDate:          modDateStr,
		CameraMake:              makeStr,
		CameraModel:             modelStr,
		LensModel:               lensStr,
		DateTimeOriginal:        dateStr,
		ExposureTime:            expStr,
		FNumber:                 fnStr,
		ISO:                     isoStr,
		FocalLength:             focalStr,
		ExposureProgram:         progStr,
		Latitude:                latVal,
		Longitude:               lonVal,
		Altitude:                altVal,
		GPSPosition:             posStr,
		GPSImgDirection:         imgDirVal,
		GPSImgDirectionRef:      imgDirRefStr,
		FocalLengthIn35mmFormat: focal35mmVal,
		YawAngle:                yawVal,
		PitchAngle:              pitchVal,
		RollAngle:               rollVal,
		FOV:                     fovStr,
		FocusDistance:           focusDistStr,
		ViewDistance:            viewDistVal,
		Country:                 countryStr,
		Province:                provStr,
		City:                    cityStr,
		District:                distStr,
		Title:                   titleStr,
		Description:             descStr,
		GPSSource:               gpsSource,
		GPSMatchMethod:          gpsMatchMethod,
		InterpolateWindow:       interpolateWindow,
		Processor:               processor,
		ProcessedDate:           processedDate,
		GeocodeSource:           geocodeSource,
		SidecarPath:             sidecarPath,
		RawTags:                 rawTags,
	}

	logger.Debugf(
		"ExifTool读取-探针", "元数据探针完成: %s (机身: %s %s, 坐标: %s, 城市: %s, 耗时: %v)",
		filepath.Base(path), makeStr, modelStr, posStr, cityStr, time.Since(start),
	)
	return result, nil
}
