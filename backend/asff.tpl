{
    "Findings": [
    {{- $t_first := true -}}
    {{- range . -}}
    {{- $target := .Target -}}
    {{- $image := .Target -}}
    {{- if gt (len $image) 127 -}}
        {{- $image = $image | regexFind ".{124}$" | printf "...%v" -}}
    {{- end}}
    {{- range .Vulnerabilities -}}
    {{- if $t_first -}}
      {{- $t_first = false -}}
    {{- else -}}
      ,
    {{- end -}}
    {{- $severity := .Severity -}}
    {{- if eq $severity "UNKNOWN" -}}
    {{- $severity = "INFORMATIONAL" -}}
    {{- end -}}
    {{- $description := .Description -}}
    {{- if gt (len $description ) 512 -}}
        {{- $description = (substr 0 512 $description) | printf "%v .." -}}
    {{- end}}
        {
            "SchemaVersion": "2018-10-08",
            "Id": "{{ $target }}/{{ .VulnerabilityID }}",
            "ProductArn": "arn:aws:securityhub:{{ env "AWS_REGION" }}::product/aquasecurity/aquasecurity",
            "GeneratorId": "Trivy/{{ .VulnerabilityID }}",
            "AwsAccountId": "{{ env "AWS_ACCOUNT_ID" }}",
            "Types": [ "Software and Configuration Checks/Vulnerabilities/CVE" ],
            "CreatedAt": "{{ now | date "2006-01-02T15:04:05.999999999Z07:00" }}",
            "UpdatedAt": "{{ now | date "2006-01-02T15:04:05.999999999Z07:00" }}",
            "Severity": {
                "Label": "{{ $severity }}"
            },
            "Title": "Trivy found a vulnerability to {{ .VulnerabilityID }} in container {{ $target }}",
            "Description": {{ escapeString $description | printf "%q" }},
            {{ if not (empty .PrimaryURL) -}}
            "Remediation": {
                "Recommendation": {
                    "Text": "More information on this vulnerability is provided in the hyperlink",
                    "Url": "{{ .PrimaryURL }}"
                }
            },
            {{ end -}}
            "ProductFields": { "Product Name": "Trivy" },
            "Resources": [
                {
                    "Type": "Container",
                    "Id": "{{ $target }}",
                    "Partition": "aws",
                    "Region": "{{ env "AWS_REGION" }}",
                    "Details": {
                        "Container": { "ImageName": "{{ $image }}" },
                        "Other": {
                            "CVE ID": "{{ .VulnerabilityID }}",
                            "CVE Title": {{ .Title | printf "%q" }},
                            "PkgName": "{{ .PkgName }}",
                            "Installed Package": "{{ .InstalledVersion }}",
                            "Patched Package": "{{ .FixedVersion }}",
                            "NvdCvssScoreV3": "{{ (index .CVSS (sourceID "nvd")).V3Score }}",
                            "NvdCvssVectorV3": "{{ (index .CVSS (sourceID "nvd")).V3Vector }}",
                            "NvdCvssScoreV2": "{{ (index .CVSS (sourceID "nvd")).V2Score }}",
                            "NvdCvssVectorV2": "{{ (index .CVSS (sourceID "nvd")).V2Vector }}"
                        }
                    }
                }
            ],
            "RecordState": "ACTIVE"
        }
        {{- end -}}
        {{- range .Misconfigurations -}}
            {{- if $t_first -}}{{- $t_first = false -}}{{- else -}},{{- end -}}
            {{- $severity := .Severity -}}
            {{- if eq $severity "UNKNOWN" -}}
                {{- $severity = "INFORMATIONAL" -}}
            {{- end -}}
            {{- $description := .Description -}}
            {{- if gt (len $description ) 512 -}}
                {{- $description = (substr 0 512 $description) | printf "%v .." -}}
            {{- end}}
        {
            "SchemaVersion": "2018-10-08",
            "Id": "{{ $target }}/{{ .ID }}",
            "ProductArn": "arn:aws:securityhub:{{ env "AWS_REGION" }}::product/aquasecurity/aquasecurity",
            "GeneratorId": "Trivy/{{ .ID }}",
            "AwsAccountId": "{{ env "AWS_ACCOUNT_ID" }}",
            "Types": [ "Software and Configuration Checks" ],
            "CreatedAt": "{{ now | date "2006-01-02T15:04:05.999999999Z07:00" }}",
            "UpdatedAt": "{{ now | date "2006-01-02T15:04:05.999999999Z07:00" }}",
            "Severity": {
                "Label": "{{ $severity }}"
            },
            "Title": "Trivy found a misconfiguration in {{ $target }}: {{ .Title }}",
            "Description": {{ escapeString $description | printf "%q" }},
            "Remediation": {
                "Recommendation": {
                    "Text": "{{ .Resolution }}",
                    "Url": "{{ .PrimaryURL }}"
                }
            },
            "ProductFields": { "Product Name": "Trivy" },
            "Resources": [
                {
                    "Type": "Other",
                    "Id": "{{ $target }}",
                    "Partition": "aws",
                    "Region": "{{ env "AWS_REGION" }}",
                    "Details": {
                        "Other": {
                            "Message": "{{ .Message }}",
                            "Filename": "{{ $target }}",
                            "StartLine": "{{ .CauseMetadata.StartLine }}",
                            "EndLine": "{{ .CauseMetadata.EndLine }}"
                        }
                    }
                }
            ],
            "RecordState": "ACTIVE"
        }
        {{- end -}}
      {{- end }}
    ]
}
