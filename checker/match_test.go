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
	"testing"

	. "github.com/onsi/gomega"

	"github.com/envoyproxy/data-plane-api/api"
	"github.com/envoyproxy/data-plane-api/api/auth"

	"github.com/projectcalico/app-policy/policystore"
	"github.com/projectcalico/app-policy/proto"
)

var (
	socketAddressProtocolTCP = &envoy_api_v2.Address{
		&envoy_api_v2.Address_SocketAddress{
			&envoy_api_v2.SocketAddress{
				Protocol: envoy_api_v2.SocketAddress_TCP,
			},
		},
	}

	socketAddressProtocolUDP = &envoy_api_v2.Address{
		&envoy_api_v2.Address_SocketAddress{
			&envoy_api_v2.SocketAddress{
				Protocol: envoy_api_v2.SocketAddress_UDP,
			},
		},
	}
)

// If no service account names are given, the clause matches any name.
func TestMatchName(t *testing.T) {
	testCases := []struct {
		title  string
		names  []string
		name   string
		result bool
	}{
		{"empty", []string{}, "reginald", true},
		{"match", []string{"susan", "jim", "reginald"}, "reginald", true},
		{"no match", []string{"susan", "jim", "reginald"}, "steven", false},
	}

	for _, tc := range testCases {
		t.Run(tc.title, func(t *testing.T) {
			RegisterTestingT(t)
			result := matchName(tc.names, tc.name)
			Expect(result).To(Equal(tc.result))
		})
	}
}

// An empty label selector matches any set of labels.
func TestMatchLabels(t *testing.T) {
	testCases := []struct {
		title    string
		selector string
		labels   map[string]string
		result   bool
	}{
		{"empty", "", map[string]string{"app": "foo", "env": "prod"}, true},
		{"bad selector", "not.a.real.selector", map[string]string{"app": "foo", "env": "prod"}, false},
		{"good selector", "app == 'foo'", map[string]string{"app": "foo", "env": "prod"}, true},
	}

	for _, tc := range testCases {
		t.Run(tc.title, func(t *testing.T) {
			RegisterTestingT(t)
			result := matchLabels(tc.selector, tc.labels)
			Expect(result).To(Equal(tc.result))
		})
	}
}

// HTTP Methods clause with empty list will match any method.
func TestMatchHTTPMethods(t *testing.T) {
	testCases := []struct {
		title   string
		methods []string
		method  string
		result  bool
	}{
		{"empty", []string{}, "GET", true},
		{"match", []string{"GET", "HEAD"}, "GET", true},
		// HTTP methods are case sensitive. https://www.w3.org/Protocols/rfc2616/rfc2616-sec5.html
		{"case sensitive", []string{"get", "HEAD"}, "GET", false},
		{"wildcard", []string{"*"}, "MADNESS", true},
	}

	for _, tc := range testCases {
		t.Run(tc.title, func(t *testing.T) {
			RegisterTestingT(t)
			Expect(matchHTTPMethods(tc.methods, tc.method)).To(Equal(tc.result))
		})
	}
}

// An omitted HTTP Match clause always matches.
func TestMatchHTTPNil(t *testing.T) {
	RegisterTestingT(t)

	req := &auth.AttributeContext_HTTPRequest{}
	Expect(matchHTTP(nil, req)).To(BeTrue())
}

// Matching a whole rule should require matching all subclauses.
func TestMatchRule(t *testing.T) {
	RegisterTestingT(t)

	rule := &proto.Rule{
		SrcServiceAccountMatch: &proto.ServiceAccountMatch{
			Names: []string{"john", "stevie", "sam"},
		},
		DstServiceAccountMatch: &proto.ServiceAccountMatch{
			Names: []string{"ian"},
		},
		HttpMatch: &proto.HTTPMatch{
			Methods: []string{"GET", "POST"},
		},
		Protocol: &proto.Protocol{
			&proto.Protocol_Name{
				Name: "TCP",
			},
		},
	}
	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{
		Source: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/default/sa/sam",
		},
		Destination: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/default/sa/ian",
			Address:   socketAddressProtocolTCP,
		},
		Request: &auth.AttributeContext_Request{
			Http: &auth.AttributeContext_HTTPRequest{
				Method: "GET",
			},
		},
	}}

	reqCache, err := NewRequestCache(policystore.NewPolicyStore(), req)
	Expect(err).To(Succeed())
	Expect(match(rule, reqCache, "")).To(BeTrue())
}

// Test namespace selectors are handled correctly
func TestMatchRuleNamespaceSelectors(t *testing.T) {
	RegisterTestingT(t)

	rule := &proto.Rule{
		OriginalSrcNamespaceSelector: "place == 'src'",
		OriginalDstNamespaceSelector: "place == 'dst'",
	}
	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{
		Source: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/src/sa/sam",
		},
		Destination: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/dst/sa/ian",
		},
		Request: &auth.AttributeContext_Request{
			Http: &auth.AttributeContext_HTTPRequest{
				Method: "GET",
			},
		},
	}}

	store := policystore.NewPolicyStore()
	id := proto.NamespaceID{Name: "src"}
	store.NamespaceByID[id] = &proto.NamespaceUpdate{Id: &id, Labels: map[string]string{"place": "src"}}
	id = proto.NamespaceID{Name: "dst"}
	store.NamespaceByID[id] = &proto.NamespaceUpdate{Id: &id, Labels: map[string]string{"place": "dst"}}
	reqCache, err := NewRequestCache(store, req)
	Expect(err).To(Succeed())
	Expect(match(rule, reqCache, "")).To(BeTrue())
}

// Test that rules only match same namespace if pod selector or service account is set
func TestMatchRulePolicyNamespace(t *testing.T) {
	RegisterTestingT(t)

	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{
		Source: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/testns/sa/sam",
		},
		Destination: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/testns/sa/ian",
		},
		Request: &auth.AttributeContext_Request{
			Http: &auth.AttributeContext_HTTPRequest{
				Method: "GET",
			},
		},
	}}

	store := policystore.NewPolicyStore()
	reqCache, err := NewRequestCache(store, req)
	Expect(err).To(Succeed())

	// With pod selector
	rule := &proto.Rule{
		OriginalSrcSelector: "has(app)",
	}
	Expect(match(rule, reqCache, "different")).To(BeFalse())
	Expect(match(rule, reqCache, "testns")).To(BeTrue())

	// With no pod selector or SA selector
	rule.OriginalSrcSelector = ""
	Expect(match(rule, reqCache, "different")).To(BeTrue())

	// With SA selector
	rule.SrcServiceAccountMatch = &proto.ServiceAccountMatch{Names: []string{"sam"}}
	Expect(match(rule, reqCache, "different")).To(BeFalse())
	Expect(match(rule, reqCache, "testns")).To(BeTrue())
}

// Test that rules match L4 protocol.
func TestMatchL4Protocol(t *testing.T) {
	RegisterTestingT(t)

	req := &auth.CheckRequest{Attributes: &auth.AttributeContext{
		Source: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/testns/sa/sam",
		},
		Destination: &auth.AttributeContext_Peer{
			Principal: "spiffe://cluster.local/ns/testns/sa/ian",
		},
		Request: &auth.AttributeContext_Request{
			Http: &auth.AttributeContext_HTTPRequest{
				Method: "GET",
			},
		},
	}}

	store := policystore.NewPolicyStore()
	reqCache, err := NewRequestCache(store, req)
	Expect(err).To(Succeed())

	// With empty rule and default request.
	rule := &proto.Rule{}
	Expect(match(rule, reqCache, "testns")).To(BeTrue())

	// With empty rule and UDP request
	req.GetAttributes().GetDestination().Address = socketAddressProtocolUDP
	Expect(match(rule, reqCache, "testns")).To(BeTrue())
	req.GetAttributes().GetDestination().Address = nil

	// With Protocol=TCP rule and default request
	rule.Protocol = &proto.Protocol{
		&proto.Protocol_Name{
			Name: "TCP",
		},
	}
	Expect(match(rule, reqCache, "testns")).To(BeTrue())
	rule.Protocol = nil

	// With Protocol=6 rule and default request
	rule.Protocol = &proto.Protocol{
		&proto.Protocol_Number{
			Number: 6,
		},
	}
	Expect(match(rule, reqCache, "testns")).To(BeTrue())
	rule.Protocol = nil

	// With Protocol=17 rule and default request
	rule.Protocol = &proto.Protocol{
		&proto.Protocol_Number{
			Number: 17,
		},
	}
	Expect(match(rule, reqCache, "testns")).To(BeFalse())
	rule.Protocol = nil

	// With Protocol!=UDP rule and default request
	rule.NotProtocol = &proto.Protocol{
		&proto.Protocol_Name{
			Name: "UDP",
		},
	}
	Expect(match(rule, reqCache, "testns")).To(BeTrue())
	rule.NotProtocol = nil

	// With Protocol!=6 rule and TCP request
	rule.NotProtocol = &proto.Protocol{
		&proto.Protocol_Number{
			Number: 6,
		},
	}
	req.GetAttributes().GetDestination().Address = socketAddressProtocolTCP
	Expect(match(rule, reqCache, "testns")).To(BeFalse())
	req.GetAttributes().GetDestination().Address = nil
	rule.NotProtocol = nil

}
