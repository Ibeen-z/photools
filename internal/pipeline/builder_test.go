package pipeline

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/vincentchyu/photools/internal/domain"
)

func TestBuild_Validation(t *testing.T) {
	// 没有启用任何插件时报错
	_, err := Build(PipelineOptions{})
	if err == nil {
		t.Fatalf("expected error when no capabilities enabled")
	}
}

func TestBuild_Success(t *testing.T) {
	tempDir := t.TempDir()
	opts := PipelineOptions{
		BaseDir:        tempDir,
		SourceDir:      filepath.Join(tempDir, "Inbox"),
		GPXDir:         filepath.Join(tempDir, "GPX"),
		ProcessedDir:   filepath.Join(tempDir, "Processed"),
		LogDir:         filepath.Join(tempDir, "Logs"),
		EnableGPXMatch: true,
		EnableGeocode:  true,
		EnableArchive:  true,
		Workers:        4,
	}

	task, err := Build(opts)
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}
	if task == nil {
		t.Fatalf("expected task instance, got nil")
	}

	orch, ok := task.(*Orchestrator)
	if !ok {
		t.Fatalf("expected *Orchestrator instance")
	}

	if len(orch.capabilities) != 3 {
		t.Errorf("expected 3 capabilities, got %d", len(orch.capabilities))
	}
}

func TestBuild_DefaultGPXDir(t *testing.T) {
	tempDir := t.TempDir()
	opts := PipelineOptions{
		BaseDir:        tempDir,
		EnableGPXMatch: true,
	}

	task, err := Build(opts)
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}
	if task == nil {
		t.Fatalf("expected task instance, got nil")
	}
}

func TestBuild_DirectSourceDefaultsProcessedBelowSource(t *testing.T) {
	tempDir := t.TempDir()
	sourceDir := filepath.Join(tempDir, "旅行照片")

	task, err := Build(
		PipelineOptions{
			BaseDir:       tempDir,
			SourceDir:     sourceDir,
			EnableArchive: true,
		},
	)
	if err != nil {
		t.Fatalf("Build failed: %v", err)
	}

	orch, ok := task.(*Orchestrator)
	if !ok {
		t.Fatalf("expected *Orchestrator instance")
	}
	if orch.sourceDir != sourceDir {
		t.Errorf("sourceDir = %q, want %q", orch.sourceDir, sourceDir)
	}

	asset := domain.AssetGroup{
		BaseName: "DSC_0001",
		RawPath:  filepath.Join(sourceDir, "DSC_0001.NEF"),
	}
	if err := os.MkdirAll(sourceDir, 0o755); err != nil {
		t.Fatalf("create source: %v", err)
	}
	if err := os.WriteFile(asset.RawPath, []byte("raw"), 0o644); err != nil {
		t.Fatalf("create asset: %v", err)
	}
	assetContext := domain.NewAssetContext(asset)
	assetContext.UpdateMetadata(domain.Metadata{DateTimeOriginal: "2026:10:10 12:00:00"})
	if err := orch.capabilities[0].ExecuteProcess(t.Context(), assetContext, nil); err != nil {
		t.Fatalf("archive direct source: %v", err)
	}
	archived := filepath.Join(sourceDir, "Processed", "2026", "1010", "DSC_2026-10-10_0001.NEF")
	if _, err := os.Stat(archived); err != nil {
		t.Errorf("expected archive below direct source %q: %v", archived, err)
	}
}
