{{- define "socialnetwork.templates.mongoDeployment" }}
{{- include "socialnetwork.templates.baseDeployment" . }}
{{- $firstPort := index .Values.container.ports 0 }}
{{- if not .Values.container.disableReadinessProbe }}
spec:
  template:
    spec:
      containers:
      - name: {{ .Values.container.name }}
        readinessProbe:
          exec:
            command:
              - mongo
              - --eval
              - "db.adminCommand('ping')"
          initialDelaySeconds: {{ .Values.container.probeInitialDelay | default .Values.global.probe.initialDelaySeconds }}
          periodSeconds: {{ .Values.container.probePeriodSeconds | default .Values.global.probe.periodSeconds }}
          failureThreshold: {{ .Values.container.probeFailureThreshold | default .Values.global.probe.failureThreshold }}
          timeoutSeconds: {{ .Values.container.probeTimeoutSeconds | default .Values.global.probe.timeoutSeconds }}
{{- end }}
{{- end }} 