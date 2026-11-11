{{- define "math.selectorLabels" -}}
app: {{ .Release.Name | quote }}
{{- end -}}

{{- define "math.labels" -}}
{{ include "math.selectorLabels" . }}
app.kubernetes.io/name: {{ .Chart.Name | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
{{- end -}}
