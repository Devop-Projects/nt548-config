{{/*
═══════════════════════════════════════════════════════════════════
templates/_helpers.tpl

Helper functions cho task-manager chart.
Không render thành K8s resource (file bắt đầu bằng _).

Cấu trúc tên: <chart-name>.<component>.<purpose>
═══════════════════════════════════════════════════════════════════
*/}}

{{/*
─────────────────────────────────────────────────────────────────
Chart-level helpers
─────────────────────────────────────────────────────────────────
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "task-manager.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified app name. Truncated at 63 chars (K8s DNS limit).
*/}}
{{- define "task-manager.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart name and version as used by the chart label.
*/}}
{{- define "task-manager.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels — đặt vào MỌI resource.
Theo recommended Kubernetes labels:
https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/
*/}}
{{- define "task-manager.labels" -}}
helm.sh/chart: {{ include "task-manager.chart" . }}
{{ include "task-manager.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: task-manager
environment: {{ .Values.global.environment }}
{{- end }}

{{/*
Selector labels — KHÔNG bao gồm version (vì selector immutable).
Quan trọng: deployment.spec.selector.matchLabels phải dùng cái này,
không phải common labels (sẽ break khi version đổi).
*/}}
{{- define "task-manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "task-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────
Backend helpers
─────────────────────────────────────────────────────────────────
*/}}

{{/*
Backend full name — tránh conflict tên giữa releases.
*/}}
{{- define "task-manager.backend.fullname" -}}
{{- printf "%s-backend" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Backend labels (common + component).
*/}}
{{- define "task-manager.backend.labels" -}}
{{ include "task-manager.labels" . }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Backend selector labels (KHÔNG có version, chart, environment).
DÙNG TRONG SELECTOR.
*/}}
{{- define "task-manager.backend.selectorLabels" -}}
app: backend
app.kubernetes.io/name: {{ include "task-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: backend
{{- end }}

{{/*
Backend full image reference.
*/}}
{{- define "task-manager.backend.image" -}}
{{- $tag := .Values.backend.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.backend.image.repository $tag -}}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────
Frontend helpers
─────────────────────────────────────────────────────────────────
*/}}

{{- define "task-manager.frontend.fullname" -}}
{{- printf "%s-frontend" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-manager.frontend.labels" -}}
{{ include "task-manager.labels" . }}
app.kubernetes.io/component: frontend
{{- end }}

{{- define "task-manager.frontend.selectorLabels" -}}
app: frontend
app.kubernetes.io/name: {{ include "task-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: frontend
{{- end }}

{{- define "task-manager.frontend.image" -}}
{{- $tag := .Values.frontend.image.tag | default .Chart.AppVersion -}}
{{- printf "%s:%s" .Values.frontend.image.repository $tag -}}
{{- end }}

{{/*
─────────────────────────────────────────────────────────────────
Postgres helpers
─────────────────────────────────────────────────────────────────
*/}}

{{- define "task-manager.postgres.fullname" -}}
{{- printf "%s-postgres" .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "task-manager.postgres.labels" -}}
{{ include "task-manager.labels" . }}
app.kubernetes.io/component: database
{{- end }}

{{- define "task-manager.postgres.selectorLabels" -}}
app: postgres
app.kubernetes.io/name: {{ include "task-manager.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: database
{{- end }}

{{- define "task-manager.postgres.image" -}}
{{- printf "%s:%s" .Values.postgres.image.repository .Values.postgres.image.tag -}}
{{- end }}

{{/*
Postgres secret name (existing hoặc generated).
*/}}
{{- define "task-manager.postgres.secretName" -}}
{{- if .Values.postgres.existingSecret -}}
{{- .Values.postgres.existingSecret -}}
{{- else -}}
postgres-secrets
{{- end -}}
{{- end }}
