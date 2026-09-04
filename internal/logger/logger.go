package logger

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/vincentchyu/photools/common"
	"github.com/vincentchyu/photools/internal/domain"
	"github.com/vincentchyu/photools/internal/i18n"
)

// Level 定义日志级别
type Level string

const (
	LevelDebug   Level = "DEBUG"
	LevelInfo    Level = "INFO"
	LevelWarn    Level = "WARN"
	LevelError   Level = "ERROR"
	LevelSuccess Level = "SUCC"
)

// Logger 全局统一日志管理器
type Logger struct {
	mu           sync.Mutex
	logDir       string
	latestFile   *os.File
	sessionFile  *os.File
	customWriter io.Writer
	disabled     bool
	inSession    bool
	startTime    time.Time
}

var (
	defaultLogger *Logger
	loggerOnce    sync.Once
)

// Default 返回全局单例 Logger
func Default() *Logger {
	loggerOnce.Do(
		func() {
			defaultLogger = &Logger{
				logDir: common.GetDefaultLogDir(),
			}
		},
	)
	return defaultLogger
}

// SetOutput 自定义输出（主要用于单元测试隔离或特殊流重定向）
func (l *Logger) SetOutput(w io.Writer) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.customWriter = w
}

// SetDisabled 控制是否彻底静音与禁用写盘
func (l *Logger) SetDisabled(disabled bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.disabled = disabled
}

// Reset 重置 Logger 状态并关闭所有打开的文件句柄
func (l *Logger) Reset() {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.sessionFile != nil {
		_ = l.sessionFile.Close()
		l.sessionFile = nil
	}
	if l.latestFile != nil {
		_ = l.latestFile.Close()
		l.latestFile = nil
	}
	l.customWriter = nil
	l.disabled = false
	l.inSession = false
	l.logDir = common.GetDefaultLogDir()
}

// InitPipelineSession 初始化流水线任务日志会话（创建时间戳日志与最新日志并写入 Header）
func (l *Logger) InitPipelineSession(logDir, taskName, sourceDir string, phases, workers int) error {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.sessionFile != nil {
		_ = l.sessionFile.Close()
		l.sessionFile = nil
	}
	if l.latestFile != nil {
		_ = l.latestFile.Close()
		l.latestFile = nil
	}

	if logDir == "" {
		logDir = common.GetDefaultLogDir()
	}
	if len(logDir) >= 2 && logDir[:2] == "~/" {
		if home, err := os.UserHomeDir(); err == nil {
			logDir = filepath.Join(home, logDir[2:])
		}
	}
	logDir, _ = filepath.Abs(logDir)
	l.logDir = logDir

	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return fmt.Errorf("创建日志目录失败 (%s): %w", logDir, err)
	}

	now := time.Now()
	l.startTime = now
	tsLogName := fmt.Sprintf("photools_%s.log", now.Format("20060102_150405"))
	tsLogPath := filepath.Join(logDir, tsLogName)
	latestLogPath := filepath.Join(logDir, common.LogFileNameLatest)

	f1, err := os.OpenFile(tsLogPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	f2, err := os.OpenFile(latestLogPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		_ = f1.Close()
		return err
	}

	l.sessionFile = f1
	l.latestFile = f2
	l.inSession = true

	// 写入执行头部信息
	headerText := fmt.Sprintf(
		"================================================================================\n"+
			"%s\n"+
			i18n.T("logFileHeaderStartTime")+"\n"+
			i18n.T("logFileHeaderTaskName")+"\n"+
			i18n.T("logFileHeaderSourceDir")+"\n"+
			i18n.T("logFileHeaderPhases")+"\n"+
			"================================================================================\n\n",
		i18n.T("logFileHeaderTitle"),
		now.Format("2006-01-02 15:04:05"), taskName, sourceDir, phases, workers,
	)

	_, _ = l.sessionFile.WriteString(headerText)
	_ = l.sessionFile.Sync()
	_, _ = l.latestFile.WriteString(headerText)
	_ = l.latestFile.Sync()

	return nil
}

// ClosePipelineSession 结束流水线任务日志会话并追加结算概览 Footer
func (l *Logger) ClosePipelineSession(summary *domain.TaskSummary, issues []domain.Issue) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if !l.inSession {
		return
	}

	totalDur := time.Since(l.startTime)
	var footer strings.Builder
	footer.WriteString("\n================================================================================\n")
	footer.WriteString(i18n.T("logFileFooterTitle") + "\n")
	footer.WriteString(
		fmt.Sprintf(
			i18n.T("logFileFooterEndTime")+"\n", time.Now().Format("2006-01-02 15:04:05"), totalDur,
		),
	)

	if summary != nil {
		footer.WriteString(fmt.Sprintf(i18n.T("logFileFooterTotal")+"\n", summary.TotalAssets))
		footer.WriteString(fmt.Sprintf(i18n.T("logFileFooterSuccess")+"\n", summary.Success))
		footer.WriteString(fmt.Sprintf(i18n.T("logFileFooterPending")+"\n", summary.Pending))
		footer.WriteString(fmt.Sprintf(i18n.T("logFileFooterFailed")+"\n", summary.Failed))
	}

	if len(issues) > 0 {
		footer.WriteString(i18n.T("logFileFooterIssuesHeader"))
		for i, iss := range issues {
			footer.WriteString(
				fmt.Sprintf(
					i18n.T("logFileFooterIssueItem"),
					i+1, iss.Asset.DisplayName(), iss.FailedStage, iss.Reason, iss.Suggestion,
				),
			)
		}
	} else {
		footer.WriteString(i18n.T("logFileFooterAllSuccess"))
	}
	footer.WriteString("================================================================================\n")

	footerStr := footer.String()

	if l.sessionFile != nil {
		_, _ = l.sessionFile.WriteString(footerStr)
		_ = l.sessionFile.Sync()
		_ = l.sessionFile.Close()
		l.sessionFile = nil
	}
	if l.latestFile != nil {
		_, _ = l.latestFile.WriteString(footerStr)
		_ = l.latestFile.Sync()
		_ = l.latestFile.Close()
		l.latestFile = nil
	}

	l.inSession = false
}

// Log 核心落盘函数：统一排版并安全写入所有活跃日志目标
func (l *Logger) Log(lvl Level, stage, message string) {
	if message == "" {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()

	if l.disabled {
		return
	}

	nowStr := time.Now().Format("15:04:05.000")
	stageStr := stage
	if stageStr == "" {
		stageStr = "ExifTool"
	}

	line := fmt.Sprintf("[%s] [%-5s] [%s] %s\n", nowStr, string(lvl), stageStr, message)

	// 1. 若配置了自定义输出（如测试 Buffer），直接写入
	if l.customWriter != nil {
		_, _ = io.WriteString(l.customWriter, line)
	}

	// 2. 若在流水线会话中，写入时间戳日志与最新日志
	if l.inSession {
		if l.sessionFile != nil {
			_, _ = l.sessionFile.WriteString(line)
			_ = l.sessionFile.Sync()
		}
		if l.latestFile != nil {
			_, _ = l.latestFile.WriteString(line)
			_ = l.latestFile.Sync()
		}
		return
	}

	// 3. 非流水线会话时（如单张操作、CLI inspect、直接写入），追加写入默认的 photools_latest.log
	if l.customWriter == nil {
		logDir := l.logDir
		if logDir == "" {
			logDir = common.GetDefaultLogDir()
		}
		_ = os.MkdirAll(logDir, 0o755)
		latestLogPath := filepath.Join(logDir, common.LogFileNameLatest)
		if f, err := os.OpenFile(latestLogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); err == nil {
			_, _ = f.WriteString(line)
			_ = f.Sync()
			_ = f.Close()
		}
	}
}

// LogEvent 从 domain.ProgressEvent 转换并落盘
func (l *Logger) LogEvent(e domain.ProgressEvent) {
	if e.Message == "" {
		return
	}

	lvl := LevelInfo
	switch e.Level {
	case domain.LevelWarn:
		lvl = LevelWarn
	case domain.LevelError:
		lvl = LevelError
	case domain.LevelSuccess:
		lvl = LevelSuccess
	}

	stageStr := domain.StageDisplayName(e.Stage)
	if stageStr == "" {
		stageStr = domain.StageDisplayName(domain.StagePrecheck)
	}

	l.Log(lvl, stageStr, e.Message)
}

// 便捷全局包级导出函数

func Debugf(stage, format string, args ...any) {
	Default().Log(LevelDebug, stage, fmt.Sprintf(format, args...))
}

func Infof(stage, format string, args ...any) {
	Default().Log(LevelInfo, stage, fmt.Sprintf(format, args...))
}

func Warnf(stage, format string, args ...any) {
	Default().Log(LevelWarn, stage, fmt.Sprintf(format, args...))
}

func Errorf(stage, format string, args ...any) {
	Default().Log(LevelError, stage, fmt.Sprintf(format, args...))
}

func Successf(stage, format string, args ...any) {
	Default().Log(LevelSuccess, stage, fmt.Sprintf(format, args...))
}

func LogEvent(e domain.ProgressEvent) {
	Default().LogEvent(e)
}

func InitPipelineSession(logDir, taskName, sourceDir string, phases, workers int) error {
	return Default().InitPipelineSession(logDir, taskName, sourceDir, phases, workers)
}

func ClosePipelineSession(summary *domain.TaskSummary, issues []domain.Issue) {
	Default().ClosePipelineSession(summary, issues)
}

func SetOutput(w io.Writer) {
	Default().SetOutput(w)
}

func SetDisabled(disabled bool) {
	Default().SetDisabled(disabled)
}

func Reset() {
	Default().Reset()
}
