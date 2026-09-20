{{- define "pgpool.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "pgpool.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "pgpool.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "pgpool.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "pgpool.selectorLabels" -}}
app.kubernetes.io/name: {{ include "pgpool.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pgpool.secretName" -}}
{{- if .Values.auth.existingSecret -}}
{{- .Values.auth.existingSecret -}}
{{- else -}}
{{- include "pgpool.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "pgpool.pcpSecretName" -}}
{{- if .Values.pcp.existingSecret -}}
{{- .Values.pcp.existingSecret -}}
{{- else -}}
{{- include "pgpool.fullname" . -}}
{{- end -}}
{{- end -}}

{{- define "pgpool.pcpEnabled" -}}
{{- if or .Values.pcp.password .Values.pcp.existingSecret -}}
true
{{- end -}}
{{- end -}}

{{- define "pgpool.backendNodes" -}}
{{- $nodes := list -}}
{{- range .Values.backends -}}
{{- if or (not (hasKey . "id")) (not (hasKey . "host")) (not (hasKey . "port")) -}}
{{- fail "each entry in .Values.backends must define id, host and port (note: `--set backends[0].x=y` replaces the whole list, so pass every field)" -}}
{{- end -}}
{{- $node := printf "%v:%s:%v" .id .host .port -}}
{{- if .weight -}}
{{- $node = printf "%s:%v" $node .weight -}}
{{- end -}}
{{- $nodes = append $nodes $node -}}
{{- end -}}
{{- if not $nodes -}}
{{- fail ".Values.backends must not be empty" -}}
{{- end -}}
{{- join "," $nodes -}}
{{- end -}}

{{- define "pgpool.backendApplicationNames" -}}
{{- $names := list -}}
{{- range .Values.backends -}}
{{- if .applicationName -}}
{{- $names = append $names (printf "%v:%s" .id .applicationName) -}}
{{- end -}}
{{- end -}}
{{- join "," $names -}}
{{- end -}}
