// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#include "vm/compiler/backend/redundancy_elimination.h"

#include <functional>

#include "vm/compiler/backend/block_builder.h"
#include "vm/compiler/backend/il_printer.h"
#include "vm/compiler/backend/il_test_helper.h"
#include "vm/compiler/backend/inliner.h"
#include "vm/compiler/backend/loops.h"
#include "vm/compiler/backend/type_propagator.h"
#include "vm/compiler/compiler_pass.h"
#include "vm/compiler/frontend/kernel_to_il.h"
#include "vm/compiler/jit/jit_call_specializer.h"
#include "vm/log.h"
#include "vm/object.h"
#include "vm/parser.h"
#include "vm/symbols.h"
#include "vm/unit_test.h"

namespace dart {

static void NoopNative(Dart_NativeArguments args) {}

static Dart_NativeFunction NoopNativeLookup(Dart_Handle name,
                                            int argument_count,
                                            bool* auto_setup_scope) {
  ASSERT(auto_setup_scope != nullptr);
  *auto_setup_scope = false;
  return reinterpret_cast<Dart_NativeFunction>(&NoopNative);
}

// Flatten all non-captured LocalVariables from the given scope and its children
// and siblings into the given array based on their environment index.
static void FlattenScopeIntoEnvironment(FlowGraph* graph,
                                        LocalScope* scope,
                                        GrowableArray<LocalVariable*>* env) {
  for (intptr_t i = 0; i < scope->num_variables(); i++) {
    auto var = scope->VariableAt(i);
    if (var->is_captured()) {
      continue;
    }

    auto index = graph->EnvIndex(var);
    env->EnsureLength(index + 1, nullptr);
    (*env)[index] = var;
  }

  if (scope->sibling() != nullptr) {
    FlattenScopeIntoEnvironment(graph, scope->sibling(), env);
  }
  if (scope->child() != nullptr) {
    FlattenScopeIntoEnvironment(graph, scope->child(), env);
  }
}

// Run TryCatchAnalyzer optimization on the function foo from the given script
// and check that the only variables from the given list are synchronized
// on catch entry.
static void TryCatchOptimizerTest(
    Thread* thread,
    const char* script_chars,
    std::initializer_list<const char*> synchronized) {
  // Load the script and exercise the code once.
  const auto& root_library =
      Library::Handle(LoadTestScript(script_chars, &NoopNativeLookup));
  Invoke(root_library, "main");

  // Build the flow graph.
  std::initializer_list<CompilerPass::Id> passes = {
      CompilerPass::kComputeSSA,      CompilerPass::kTypePropagation,
      CompilerPass::kApplyICData,     CompilerPass::kSelectRepresentations,
      CompilerPass::kTypePropagation, CompilerPass::kCanonicalize,
  };
  const auto& function = Function::Handle(GetFunction(root_library, "foo"));
  TestPipeline pipeline(function, CompilerPass::kJIT);
  FlowGraph* graph = pipeline.RunPasses(passes);

  // Finally run TryCatchAnalyzer on the graph (in AOT mode).
  OptimizeCatchEntryStates(graph, /*is_aot=*/true);

  EXPECT_EQ(1, graph->graph_entry()->catch_entries().length());
  auto scope = graph->parsed_function().node_sequence()->scope();

  GrowableArray<LocalVariable*> env;
  FlattenScopeIntoEnvironment(graph, scope, &env);

  for (intptr_t i = 0; i < env.length(); i++) {
    bool found = false;
    for (auto name : synchronized) {
      if (env[i]->name().Equals(name)) {
        found = true;
        break;
      }
    }
    if (!found) {
      env[i] = nullptr;
    }
  }

  CatchBlockEntryInstr* catch_entry = graph->graph_entry()->catch_entries()[0];

  // We should only synchronize state for variables from the synchronized list.
  for (auto defn : *catch_entry->initial_definitions()) {
    if (ParameterInstr* param = defn->AsParameter()) {
      EXPECT(0 <= param->index() && param->index() < env.length());
      EXPECT(env[param->index()] != nullptr);
    }
  }
}

//
// Tests for TryCatchOptimizer.
//

ISOLATE_UNIT_TEST_CASE(TryCatchOptimizer_DeadParameterElimination_Simple1) {
  const char* script_chars = R"(
      dynamic blackhole([dynamic val]) native 'BlackholeNative';
      foo(int p) {
        var a = blackhole(), b = blackhole();
        try {
          blackhole([a, b]);
        } catch (e) {
          // nothing is used
        }
      }
      main() {
        foo(42);
      }
  )";

  TryCatchOptimizerTest(thread, script_chars, /*synchronized=*/{});
}

ISOLATE_UNIT_TEST_CASE(TryCatchOptimizer_DeadParameterElimination_Simple2) {
  const char* script_chars = R"(
      dynamic blackhole([dynamic val]) native 'BlackholeNative';
      foo(int p) {
        var a = blackhole(), b = blackhole();
        try {
          blackhole([a, b]);
        } catch (e) {
          // a should be synchronized
          blackhole(a);
        }
      }
      main() {
        foo(42);
      }
  )";

  TryCatchOptimizerTest(thread, script_chars, /*synchronized=*/{"a"});
}

ISOLATE_UNIT_TEST_CASE(TryCatchOptimizer_DeadParameterElimination_Cyclic1) {
  const char* script_chars = R"(
      dynamic blackhole([dynamic val]) native 'BlackholeNative';
      foo(int p) {
        var a = blackhole(), b;
        for (var i = 0; i < 42; i++) {
          b = blackhole();
          try {
            blackhole([a, b]);
          } catch (e) {
            // a and i should be synchronized
          }
        }
      }
      main() {
        foo(42);
      }
  )";

  TryCatchOptimizerTest(thread, script_chars, /*synchronized=*/{"a", "i"});
}

ISOLATE_UNIT_TEST_CASE(TryCatchOptimizer_DeadParameterElimination_Cyclic2) {
  const char* script_chars = R"(
      dynamic blackhole([dynamic val]) native 'BlackholeNative';
      foo(int p) {
        var a = blackhole(), b = blackhole();
        for (var i = 0; i < 42; i++) {
          try {
            blackhole([a, b]);
          } catch (e) {
            // a, b and i should be synchronized
          }
        }
      }
      main() {
        foo(42);
      }
  )";

  TryCatchOptimizerTest(thread, script_chars, /*synchronized=*/{"a", "b", "i"});
}

// LoadOptimizer tests

// This family of tests verifies behavior of load forwarding when alias for an
// allocation A is created by creating a redefinition for it and then
// letting redefinition escape.
static void TestAliasingViaRedefinition(
    Thread* thread,
    bool make_it_escape,
    std::function<Definition*(CompilerState* S, FlowGraph*, Definition*)>
        make_redefinition) {
  const char* script_chars = R"(
    dynamic blackhole([a, b, c, d, e, f]) native 'BlackholeNative';
    class K {
      var field;
    }
  )";
  const Library& lib =
      Library::Handle(LoadTestScript(script_chars, NoopNativeLookup));

  const Class& cls = Class::Handle(
      lib.LookupLocalClass(String::Handle(Symbols::New(thread, "K"))));
  const Error& err = Error::Handle(cls.EnsureIsFinalized(thread));
  EXPECT(err.IsNull());

  const Field& field = Field::Handle(
      cls.LookupField(String::Handle(Symbols::New(thread, "field"))));
  EXPECT(!field.IsNull());

  const Function& blackhole =
      Function::ZoneHandle(GetFunction(lib, "blackhole"));

  using compiler::BlockBuilder;
  CompilerState S(thread);
  FlowGraphBuilderHelper H;

  // We are going to build the following graph:
  //
  // B0[graph_entry]
  // B1[function_entry]:
  //   v0 <- AllocateObject(class K)
  //   v1 <- LoadField(v0, K.field)
  //   v2 <- make_redefinition(v0)
  //   PushArgument(v1)
  // #if make_it_escape
  //   PushArgument(v2)
  // #endif
  //   v3 <- StaticCall(blackhole, v1, v2)
  //   v4 <- LoadField(v2, K.field)
  //   Return v4

  auto b1 = H.flow_graph()->graph_entry()->normal_entry();
  AllocateObjectInstr* v0;
  LoadFieldInstr* v1;
  PushArgumentInstr* push_v1;
  LoadFieldInstr* v4;
  ReturnInstr* ret;

  {
    BlockBuilder builder(H.flow_graph(), b1);
    auto& slot = Slot::Get(field, &H.flow_graph()->parsed_function());
    v0 = builder.AddDefinition(new AllocateObjectInstr(
        TokenPosition::kNoSource, cls, new PushArgumentsArray(0)));
    v1 = builder.AddDefinition(
        new LoadFieldInstr(new Value(v0), slot, TokenPosition::kNoSource));
    auto v2 = builder.AddDefinition(make_redefinition(&S, H.flow_graph(), v0));
    auto args = new PushArgumentsArray(2);
    push_v1 = builder.AddInstruction(new PushArgumentInstr(new Value(v1)));
    args->Add(push_v1);
    if (make_it_escape) {
      auto push_v2 =
          builder.AddInstruction(new PushArgumentInstr(new Value(v2)));
      args->Add(push_v2);
    }
    builder.AddInstruction(new StaticCallInstr(
        TokenPosition::kNoSource, blackhole, 0, Array::empty_array(), args,
        S.GetNextDeoptId(), 0, ICData::RebindRule::kStatic));
    v4 = builder.AddDefinition(
        new LoadFieldInstr(new Value(v2), slot, TokenPosition::kNoSource));
    ret = builder.AddInstruction(new ReturnInstr(
        TokenPosition::kNoSource, new Value(v4), S.GetNextDeoptId()));
  }
  H.FinishGraph();
  DominatorBasedCSE::Optimize(H.flow_graph());

  if (make_it_escape) {
    // Allocation must be considered aliased.
    EXPECT_PROPERTY(v0, !it.Identity().IsNotAliased());
  } else {
    // Allocation must be considered not-aliased.
    EXPECT_PROPERTY(v0, it.Identity().IsNotAliased());
  }

  // v1 should have been removed from the graph and replaced with constant_null.
  EXPECT_PROPERTY(v1, it.next() == nullptr && it.previous() == nullptr);
  EXPECT_PROPERTY(push_v1,
                  it.value()->definition() == H.flow_graph()->constant_null());

  if (make_it_escape) {
    // v4 however should not be removed from the graph, because v0 escapes into
    // blackhole.
    EXPECT_PROPERTY(v4, it.next() != nullptr && it.previous() != nullptr);
    EXPECT_PROPERTY(ret, it.value()->definition() == v4);
  } else {
    // If v0 it not aliased then v4 should also be removed from the graph.
    EXPECT_PROPERTY(v4, it.next() == nullptr && it.previous() == nullptr);
    EXPECT_PROPERTY(
        ret, it.value()->definition() == H.flow_graph()->constant_null());
  }
}

static Definition* MakeCheckNull(CompilerState* S,
                                 FlowGraph* flow_graph,
                                 Definition* defn) {
  return new CheckNullInstr(new Value(defn), String::ZoneHandle(),
                            S->GetNextDeoptId(), TokenPosition::kNoSource);
}

static Definition* MakeRedefinition(CompilerState* S,
                                    FlowGraph* flow_graph,
                                    Definition* defn) {
  return new RedefinitionInstr(new Value(defn));
}

static Definition* MakeAssertAssignable(CompilerState* S,
                                        FlowGraph* flow_graph,
                                        Definition* defn) {
  return new AssertAssignableInstr(TokenPosition::kNoSource, new Value(defn),
                                   new Value(flow_graph->constant_null()),
                                   new Value(flow_graph->constant_null()),
                                   AbstractType::ZoneHandle(Type::ObjectType()),
                                   Symbols::Empty(), S->GetNextDeoptId());
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_RedefinitionAliasing_CheckNull_NoEscape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/false, MakeCheckNull);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_RedefinitionAliasing_CheckNull_Escape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/true, MakeCheckNull);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_RedefinitionAliasing_Redefinition_NoEscape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/false,
                              MakeRedefinition);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_RedefinitionAliasing_Redefinition_Escape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/true,
                              MakeRedefinition);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_RedefinitionAliasing_AssertAssignable_NoEscape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/false,
                              MakeAssertAssignable);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_RedefinitionAliasing_AssertAssignable_Escape) {
  TestAliasingViaRedefinition(thread, /*make_it_escape=*/true,
                              MakeAssertAssignable);
}

// This family of tests verifies behavior of load forwarding when alias for an
// allocation A is created by storing it into another object B and then
// either loaded from it ([make_it_escape] is true) or object B itself
// escapes ([make_host_escape] is true).
// We insert redefinition for object B to check that use list traversal
// correctly discovers all loads and stores from B.
static void TestAliasingViaStore(
    Thread* thread,
    bool make_it_escape,
    bool make_host_escape,
    std::function<Definition*(CompilerState* S, FlowGraph*, Definition*)>
        make_redefinition) {
  const char* script_chars = R"(
    dynamic blackhole([a, b, c, d, e, f]) native 'BlackholeNative';
    class K {
      var field;
    }
  )";
  const Library& lib =
      Library::Handle(LoadTestScript(script_chars, NoopNativeLookup));

  const Class& cls = Class::Handle(
      lib.LookupLocalClass(String::Handle(Symbols::New(thread, "K"))));
  const Error& err = Error::Handle(cls.EnsureIsFinalized(thread));
  EXPECT(err.IsNull());

  const Field& field = Field::Handle(
      cls.LookupField(String::Handle(Symbols::New(thread, "field"))));
  EXPECT(!field.IsNull());

  const Function& blackhole =
      Function::ZoneHandle(GetFunction(lib, "blackhole"));

  using compiler::BlockBuilder;
  CompilerState S(thread);
  FlowGraphBuilderHelper H;

  // We are going to build the following graph:
  //
  // B0[graph_entry]
  // B1[function_entry]:
  //   v0 <- AllocateObject(class K)
  //   v5 <- AllocateObject(class K)
  // #if !make_host_escape
  //   StoreField(v5 . K.field = v0)
  // #endif
  //   v1 <- LoadField(v0, K.field)
  //   v2 <- REDEFINITION(v5)
  //   PushArgument(v1)
  // #if make_it_escape
  //   v6 <- LoadField(v2, K.field)
  //   PushArgument(v6)
  // #elif make_host_escape
  //   StoreField(v2 . K.field = v0)
  //   PushArgument(v5)
  // #endif
  //   v3 <- StaticCall(blackhole, v1, v6)
  //   v4 <- LoadField(v0, K.field)
  //   Return v4

  auto b1 = H.flow_graph()->graph_entry()->normal_entry();
  AllocateObjectInstr* v0;
  AllocateObjectInstr* v5;
  LoadFieldInstr* v1;
  PushArgumentInstr* push_v1;
  LoadFieldInstr* v4;
  ReturnInstr* ret;

  {
    BlockBuilder builder(H.flow_graph(), b1);
    auto& slot = Slot::Get(field, &H.flow_graph()->parsed_function());
    v0 = builder.AddDefinition(new AllocateObjectInstr(
        TokenPosition::kNoSource, cls, new PushArgumentsArray(0)));
    v5 = builder.AddDefinition(new AllocateObjectInstr(
        TokenPosition::kNoSource, cls, new PushArgumentsArray(0)));
    if (!make_host_escape) {
      builder.AddInstruction(new StoreInstanceFieldInstr(
          slot, new Value(v5), new Value(v0), kEmitStoreBarrier,
          TokenPosition::kNoSource));
    }
    v1 = builder.AddDefinition(
        new LoadFieldInstr(new Value(v0), slot, TokenPosition::kNoSource));
    auto v2 = builder.AddDefinition(make_redefinition(&S, H.flow_graph(), v5));
    push_v1 = builder.AddInstruction(new PushArgumentInstr(new Value(v1)));
    auto args = new PushArgumentsArray(2);
    args->Add(push_v1);
    if (make_it_escape) {
      auto v6 = builder.AddDefinition(
          new LoadFieldInstr(new Value(v2), slot, TokenPosition::kNoSource));
      auto push_v6 =
          builder.AddInstruction(new PushArgumentInstr(new Value(v6)));
      args->Add(push_v6);
    } else if (make_host_escape) {
      builder.AddInstruction(new StoreInstanceFieldInstr(
          slot, new Value(v2), new Value(v0), kEmitStoreBarrier,
          TokenPosition::kNoSource));
      args->Add(builder.AddInstruction(new PushArgumentInstr(new Value(v5))));
    }
    builder.AddInstruction(new StaticCallInstr(
        TokenPosition::kNoSource, blackhole, 0, Array::empty_array(), args,
        S.GetNextDeoptId(), 0, ICData::RebindRule::kStatic));
    v4 = builder.AddDefinition(
        new LoadFieldInstr(new Value(v0), slot, TokenPosition::kNoSource));
    ret = builder.AddInstruction(new ReturnInstr(
        TokenPosition::kNoSource, new Value(v4), S.GetNextDeoptId()));
  }
  H.FinishGraph();
  DominatorBasedCSE::Optimize(H.flow_graph());

  if (make_it_escape || make_host_escape) {
    // Allocation must be considered aliased.
    EXPECT_PROPERTY(v0, !it.Identity().IsNotAliased());
  } else {
    // Allocation must not be considered aliased.
    EXPECT_PROPERTY(v0, it.Identity().IsNotAliased());
  }

  if (make_host_escape) {
    EXPECT_PROPERTY(v5, !it.Identity().IsNotAliased());
  } else {
    EXPECT_PROPERTY(v5, it.Identity().IsNotAliased());
  }

  // v1 should have been removed from the graph and replaced with constant_null.
  EXPECT_PROPERTY(v1, it.next() == nullptr && it.previous() == nullptr);
  EXPECT_PROPERTY(push_v1,
                  it.value()->definition() == H.flow_graph()->constant_null());

  if (make_it_escape || make_host_escape) {
    // v4 however should not be removed from the graph, because v0 escapes into
    // blackhole.
    EXPECT_PROPERTY(v4, it.next() != nullptr && it.previous() != nullptr);
    EXPECT_PROPERTY(ret, it.value()->definition() == v4);
  } else {
    // If v0 it not aliased then v4 should also be removed from the graph.
    EXPECT_PROPERTY(v4, it.next() == nullptr && it.previous() == nullptr);
    EXPECT_PROPERTY(
        ret, it.value()->definition() == H.flow_graph()->constant_null());
  }
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_CheckNull_NoEscape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ false, MakeCheckNull);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_CheckNull_Escape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/true,
                       /* make_host_escape= */ false, MakeCheckNull);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_CheckNull_EscapeViaHost) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ true, MakeCheckNull);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_Redefinition_NoEscape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ false, MakeRedefinition);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_Redefinition_Escape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/true,
                       /* make_host_escape= */ false, MakeRedefinition);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_AliasingViaStore_Redefinition_EscapeViaHost) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ true, MakeRedefinition);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_AliasingViaStore_AssertAssignable_NoEscape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ false, MakeAssertAssignable);
}

ISOLATE_UNIT_TEST_CASE(LoadOptimizer_AliasingViaStore_AssertAssignable_Escape) {
  TestAliasingViaStore(thread, /*make_it_escape=*/true,
                       /* make_host_escape= */ false, MakeAssertAssignable);
}

ISOLATE_UNIT_TEST_CASE(
    LoadOptimizer_AliasingViaStore_AssertAssignable_EscapeViaHost) {
  TestAliasingViaStore(thread, /*make_it_escape=*/false,
                       /* make_host_escape= */ true, MakeAssertAssignable);
}

}  // namespace dart
