// Copyright (c) 2018 Tigera, Inc. All rights reserved.

// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package checker

import (
	"github.com/projectcalico/app-policy/proto"
	"github.com/projectcalico/libcalico-go/lib/selector"

	"strings"

	authz "github.com/envoyproxy/data-plane-api/api/auth"
	log "github.com/sirupsen/logrus"
)

type namespaceMatch struct {
	Names    []string
	Selector string
}

// match checks if the Rule matches the request.  It returns true if the Rule matches, false otherwise.
func match(rule *proto.Rule, req *requestCache, policyNamespace string) bool {
	log.Debugf("Checking rule %v on request %v", rule, req)
	attr := req.Request.GetAttributes()
	return matchSource(rule, req, policyNamespace) &&
		matchDestination(rule, req, policyNamespace) &&
		matchRequest(rule, attr.GetRequest()) &&
		matchL4Protocol(rule, attr.GetDestination())
}

func matchSource(r *proto.Rule, req *requestCache, policyNamespace string) bool {
	nsMatch := computeNamespaceMatch(
		policyNamespace,
		r.GetOriginalSrcNamespaceSelector(),
		r.GetOriginalSrcSelector(),
		r.GetOriginalNotSrcSelector(),
		r.GetSrcServiceAccountMatch())
	return matchServiceAccounts(r.GetSrcServiceAccountMatch(), req.SourcePeer()) &&
		matchNamespace(nsMatch, req.SourceNamespace())
}

func computeNamespaceMatch(
	policyNamespace, nsSelector, podSelector, notPodSelector string, saMatch *proto.ServiceAccountMatch,
) *namespaceMatch {
	nsMatch := &namespaceMatch{}
	if nsSelector != "" {
		// In all cases, if a namespace label selector is present, it takes precedence.
		nsMatch.Selector = nsSelector
	} else {
		// NetworkPolicies have `policyNamespace` set, GlobalNetworkPolicy and Profiles have it set to empty string.
		// If this is a NetworkPolicy and there is pod label selector (or not selector) or service account match, then
		// we must only accept connections from this namespace.  GlobalNetworkPolicy, Profile, or those without a pod
		// selector/service account match can match any namespace.
		if policyNamespace != "" &&
			(podSelector != "" ||
				notPodSelector != "" ||
				len(saMatch.GetNames()) != 0 ||
				saMatch.GetSelector() != "") {
			nsMatch.Names = []string{policyNamespace}
		}
	}
	return nsMatch
}

func matchDestination(r *proto.Rule, req *requestCache, policyNamespace string) bool {
	nsMatch := computeNamespaceMatch(
		policyNamespace,
		r.GetOriginalDstNamespaceSelector(),
		r.GetOriginalDstSelector(),
		r.GetOriginalNotDstSelector(),
		r.GetDstServiceAccountMatch())
	return matchServiceAccounts(r.GetDstServiceAccountMatch(), req.DestinationPeer()) &&
		matchNamespace(nsMatch, req.DestinationNamespace())
}

func matchRequest(rule *proto.Rule, req *authz.AttributeContext_Request) bool {
	log.WithField("request", req).Debug("Matching request.")
	return matchHTTP(rule.GetHttpMatch(), req.GetHttp())
}

func matchServiceAccounts(saMatch *proto.ServiceAccountMatch, p peer) bool {
	log.WithFields(log.Fields{
		"name":      p.Name,
		"namespace": p.Namespace,
		"labels":    p.Labels,
		"rule":      saMatch},
	).Debug("Matching service account.")
	if saMatch == nil {
		log.Debug("nil ServiceAccountMatch.  Return true.")
		return true
	}
	return matchName(saMatch.GetNames(), p.Name) &&
		matchLabels(saMatch.GetSelector(), p.Labels)
}

func matchName(names []string, name string) bool {
	log.WithFields(log.Fields{
		"names": names,
		"name":  name,
	}).Debug("Matching name")
	if len(names) == 0 {
		log.Debug("No names on rule.")
		return true
	}
	for _, n := range names {
		if n == name {
			return true
		}
	}
	return false
}

func matchLabels(selectorStr string, labels map[string]string) bool {
	log.WithFields(log.Fields{
		"selector": selectorStr,
		"labels":   labels,
	}).Debug("Matching labels.")
	sel, err := selector.Parse(selectorStr)
	if err != nil {
		log.Warnf("Could not parse label selector %v, %v", selectorStr, err)
		return false
	}
	log.Debugf("Parsed selector.", sel)
	return sel.Evaluate(labels)
}

func matchNamespace(nsMatch *namespaceMatch, ns namespace) bool {
	log.WithFields(log.Fields{
		"namespace": ns.Name,
		"labels":    ns.Labels,
		"rule":      nsMatch},
	).Debug("Matching namespace.")
	return matchName(nsMatch.Names, ns.Name) && matchLabels(nsMatch.Selector, ns.Labels)
}

func matchHTTP(rule *proto.HTTPMatch, req *authz.AttributeContext_HTTPRequest) bool {
	log.WithFields(log.Fields{
		"rule": rule,
	}).Debug("Matching HTTP.")
	if rule == nil {
		log.Debug("nil HTTPRule.  Return true")
		return true
	}
	return matchHTTPMethods(rule.GetMethods(), req.GetMethod())
}

func matchHTTPMethods(methods []string, reqMethod string) bool {
	log.WithFields(log.Fields{
		"methods":   methods,
		"reqMethod": reqMethod,
	}).Debug("Matching HTTP Methods")
	if len(methods) == 0 {
		log.Debug("Rule has 0 HTTP Methods, matched.")
		return true
	}
	for _, method := range methods {
		if method == "*" {
			log.Debug("Rule matches all methods with wildcard *")
			return true
		}
		if method == reqMethod {
			log.Debug("HTTP Method matched.")
			return true
		}
	}
	log.Debug("HTTP Method not matched.")
	return false
}

func matchL4Protocol(rule *proto.Rule, dest *authz.AttributeContext_Peer) bool {
	// Extract L4 protocol type of socket address for destination peer context. Match against rules.
	if dest == nil {
		log.Warn("nil request destination peer.")
		return false
	}

	// default protocol is TCP
	reqProtocol := "TCP"
	if a := dest.GetAddress(); a != nil {
		if sa := a.GetSocketAddress(); sa != nil {
			reqProtocol = sa.GetProtocol().String()
		}
	}

	checkStringInRuleProtocol := func(p *proto.Protocol, s string) bool {
		// Check if given protocol string matches what is specified in rule.
		if name := p.GetName(); name != "" {
			return strings.ToLower(name) == strings.ToLower(s)
		}

		// Envoy supports TCP only. Add a k:v into the map if more protocol is supported in the future.
		protocolMap := map[int32]string{6: "TCP"}
		if name, ok := protocolMap[p.GetNumber()]; ok {
			return strings.ToLower(name) == strings.ToLower(s)
		}

		return false
	}

	// Check protocol in rule first.
	if protocal := rule.GetProtocol(); protocal != nil {
		return checkStringInRuleProtocol(protocal, reqProtocol)
	}

	// Check notProtocol.
	if protocal := rule.GetNotProtocol(); protocal != nil {
		return !checkStringInRuleProtocol(protocal, reqProtocol)
	}

	// Match all protocols.
	return true
}
