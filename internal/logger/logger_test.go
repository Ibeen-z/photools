package logger

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/vincentchyu/photools/common"
	"github.com/vincentchyu/photools/internal/domain"
)

func TestLogger_BasicLogging(t *testing.T) {
	var buf bytes.Buffer
	l := &Logger{}
	l.SetOutput(&buf)

	l.Log(LevelInfo, "ExifTool读取", "成功读取 DSC_0001.NEF 拍摄时间")
	l.Log(LevelWarn, "ExifTool写入", "GPS 写入漂移微调")
	l.Log(LevelError, "ExifTool写入", "写入失败: command not found")
	l.Log(LevelSuccess, "ExifTool校验", "二次读取校验通过")

	out := buf.String()
	if !strings.Contains(out, "[INFO ] [ExifTool读取] 成功读取 DSC_0001.NEF 拍摄时间") {
		t.Errorf("expected info log, got:\n%s", out)
	}
	if !strings.Contains(out, "[WARN ] [ExifTool写入] GPS 写入漂移微调") {
		t.Errorf("expected warn log, got:\n%s", out)
	}
	if !strings.Contains(out, "[ERROR] [ExifTool写入] 写入失败: command not found") {
		t.Errorf("expected error log, got:\n%s", out)
	}
	if !strings.Contains(out, "[SUCC ] [ExifTool校验] 二次读取校验通过") {
		t.Errorf("expected succ log, got:\n%s", out)
	}
}

func TestLogger_PipelineSession(t *testing.T) {
	tmpDir := t.TempDir()
	l := &Logger{}

	err := l.InitPipelineSession(tmpDir, "测试任务", "/tmp/photos", 3, 4)
	if err != nil {
		t.Fatalf("InitPipelineSession 失败: %v", err)
	}

	l.Log(LevelInfo, "ExifTool读取", "预读元数据 10 组")
	l.Log(LevelSuccess, "ExifTool写入", "写入 GPS 坐标成功")

	summary := &domain.TaskSummary{
		TotalAssets: 1,
		Success:     1,
		Pending:     0,
		Failed:      0,
	}
	l.ClosePipelineSession(summary, nil)

	// 验证 latest 日志
	latestPath := filepath.Join(tmpDir, common.LogFileNameLatest)
	latestContent, err := os.ReadFile(latestPath)
	if err != nil {
		t.Fatalf("读取 latest 日志失败: %v", err)
	}
	s := string(latestContent)
	if !strings.Contains(s, "photools 流水线执行日志") {
		t.Errorf("expected header, got:\n%s", s)
	}
	if !strings.Contains(s, "预读元数据 10 组") {
		t.Errorf("expected read log, got:\n%s", s)
	}
	if !strings.Contains(s, "流水线执行结算概览") {
		t.Errorf("expected footer, got:\n%s", s)
	}

	// 验证时间戳日志
	matches, _ := filepath.Glob(filepath.Join(tmpDir, "photools_*.log"))
	if len(matches) < 2 {
		t.Errorf("expected at least 2 log files in %s, got: %v", tmpDir, matches)
	}
}

func TestLogger_DisabledAndReset(t *testing.T) {
	var buf bytes.Buffer
	l := &Logger{}
	l.SetOutput(&buf)
	l.SetDisabled(true)

	l.Log(LevelInfo, "Test", "should not appear")
	if buf.Len() > 0 {
		t.Errorf("expected empty buffer when disabled, got: %s", buf.String())
	}

	l.SetDisabled(false)
	l.Log(LevelInfo, "Test", "should appear")
	if !strings.Contains(buf.String(), "should appear") {
		t.Errorf("expected log after re-enabling, got: %s", buf.String())
	}

	l.Reset()
	if l.disabled || l.inSession {
		t.Errorf("expected reset state, got %+v", l)
	}
}

func TestLogger_ConcurrentLogging(t *testing.T) {
	var buf bytes.Buffer
	l := &Logger{}
	l.SetOutput(&buf)

	var wg sync.WaitGroup
	workers := 10
	itemsPerWorker := 50

	for i := 0; i < workers; i++ {
		workerID := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < itemsPerWorker; j++ {
				l.Log(LevelInfo, "Concurrent", "worker message")
			}
		}()
		_ = workerID
	}

	wg.Wait()
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != workers*itemsPerWorker {
		t.Errorf("expected %d lines, got %d", workers*itemsPerWorker, len(lines))
	}
}

func TestLogger_GlobalHelpers(t *testing.T) {
	var buf bytes.Buffer
	SetOutput(&buf)
	defer Reset()

	Infof("ExifTool读取", "信息 %d", 1)
	Warnf("ExifTool写入", "警告 %s", "test")
	Errorf("ExifTool写入", "错误 %v", "err")
	Successf("ExifTool校验", "成功 %s", "ok")
	Debugf("ExifTool进程", "调试 %d", 123)

	LogEvent(
		domain.ProgressEvent{
			Stage:   domain.StageGeotag,
			Level:   domain.LevelSuccess,
			Message: "事件写入成功",
		},
	)

	out := buf.String()
	if !strings.Contains(out, "信息 1") || !strings.Contains(out, "警告 test") ||
		!strings.Contains(out, "错误 err") || !strings.Contains(out, "成功 ok") ||
		!strings.Contains(out, "调试 123") || !strings.Contains(out, "事件写入成功") {
		t.Errorf("global helpers log missing content:\n%s", out)
	}
}
