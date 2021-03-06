// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:collection';

import '../common.dart';
import '../common/names.dart' show Identifiers;
import '../common_elements.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../js_backend/native_data.dart' show NativeBasicData;
import '../js_model/elements.dart' show JSignatureMethod;
import '../util/enumset.dart';
import '../util/util.dart';
import '../world.dart';
import 'call_structure.dart';
import 'member_usage.dart';
import 'selector.dart' show Selector;
import 'use.dart'
    show ConstantUse, DynamicUse, DynamicUseKind, StaticUse, StaticUseKind;
import 'world_builder.dart';

/// World builder specific to codegen.
///
/// This adds additional access to liveness of selectors and elements.
abstract class CodegenWorldBuilder implements WorldBuilder {
  /// Register [constant] as needed for emission.
  void addCompileTimeConstantForEmission(ConstantValue constant);

  /// Close the codegen world builder and return the immutable [CodegenWorld]
  /// as the result.
  CodegenWorld close();
}

// The immutable result of the [CodegenWorldBuilder].
abstract class CodegenWorld extends BuiltWorld {
  void forEachInvokedName(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  void forEachInvokedGetter(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  void forEachInvokedSetter(
      f(String name, Map<Selector, SelectorConstraints> selectors));

  /// All directly instantiated classes, that is, classes with a generative
  /// constructor that has been called directly and not only through a
  /// super-call.
  // TODO(johnniwinther): Improve semantic precision.
  Iterable<ClassEntity> get directlyInstantiatedClasses;

  /// All directly or indirectly instantiated classes.
  Iterable<ClassEntity> get instantiatedClasses;

  Iterable<FunctionEntity> get methodsNeedingSuperGetter;

  /// The set of all referenced static fields.
  ///
  /// Invariant: Elements are declaration elements.
  Iterable<FieldEntity> get allReferencedStaticFields;

  /// Returns the types that are live as constant type literals.
  Iterable<DartType> get constTypeLiterals;

  /// Returns the types that are live as constant type arguments.
  Iterable<DartType> get liveTypeArguments;

  Map<Selector, SelectorConstraints> invocationsByName(String name);

  /// Returns a list of constants topologically sorted so that dependencies
  /// appear before the dependent constant.
  ///
  /// [preSortCompare] is a comparator function that gives the constants a
  /// consistent order prior to the topological sort which gives the constants
  /// an ordering that is less sensitive to perturbations in the source code.
  List<ConstantValue> getConstantsForEmission(
      [Comparator<ConstantValue> preSortCompare]);

  Map<Selector, SelectorConstraints> getterInvocationsByName(String name);

  Map<Selector, SelectorConstraints> setterInvocationsByName(String name);

  bool hasInvokedGetter(MemberEntity member);

  /// Returns `true` if [member] is invoked as a setter.
  bool hasInvokedSetter(MemberEntity member);
}

class CodegenWorldBuilderImpl extends WorldBuilderBase
    implements CodegenWorldBuilder {
  final JClosedWorld _closedWorld;

  /// The set of all directly instantiated classes, that is, classes with a
  /// generative constructor that has been called directly and not only through
  /// a super-call.
  ///
  /// Invariant: Elements are declaration elements.
  // TODO(johnniwinther): [_directlyInstantiatedClasses] and
  // [_instantiatedTypes] sets should be merged.
  final Set<ClassEntity> _directlyInstantiatedClasses = new Set<ClassEntity>();

  /// The set of all directly instantiated types, that is, the types of the
  /// directly instantiated classes.
  ///
  /// See [_directlyInstantiatedClasses].
  final Set<InterfaceType> _instantiatedTypes = new Set<InterfaceType>();

  /// Classes implemented by directly instantiated classes.
  final Set<ClassEntity> _implementedClasses = new Set<ClassEntity>();

  final Set<FieldEntity> _allReferencedStaticFields = new Set<FieldEntity>();

  final Set<FunctionEntity> _methodsNeedingSuperGetter =
      new Set<FunctionEntity>();
  final Map<String, Map<Selector, SelectorConstraints>> _invokedNames =
      <String, Map<Selector, SelectorConstraints>>{};
  final Map<String, Map<Selector, SelectorConstraints>> _invokedGetters =
      <String, Map<Selector, SelectorConstraints>>{};
  final Map<String, Map<Selector, SelectorConstraints>> _invokedSetters =
      <String, Map<Selector, SelectorConstraints>>{};

  final Map<ClassEntity, ClassUsage> _processedClasses =
      <ClassEntity, ClassUsage>{};

  Map<ClassEntity, ClassUsage> get classUsageForTesting => _processedClasses;

  /// Map of registered usage of static and instance members.
  final Map<MemberEntity, MemberUsage> _memberUsage =
      <MemberEntity, MemberUsage>{};

  /// Map containing instance members of live classes that are not yet live
  /// themselves.
  final Map<String, Set<MemberUsage>> _instanceMembersByName =
      <String, Set<MemberUsage>>{};

  /// Map containing instance methods of live classes that are not yet
  /// closurized.
  final Map<String, Set<MemberUsage>> _instanceFunctionsByName =
      <String, Set<MemberUsage>>{};

  final Set<DartType> _isChecks = new Set<DartType>();

  final SelectorConstraintsStrategy _selectorConstraintsStrategy;

  final Set<ConstantValue> _constantValues = new Set<ConstantValue>();

  final Set<DartType> _constTypeLiterals = new Set<DartType>();
  final Set<DartType> _liveTypeArguments = new Set<DartType>();

  CodegenWorldBuilderImpl(this._closedWorld, this._selectorConstraintsStrategy);

  ElementEnvironment get _elementEnvironment => _closedWorld.elementEnvironment;

  NativeBasicData get _nativeBasicData => _closedWorld.nativeData;

  Iterable<ClassEntity> get instantiatedClasses => _processedClasses.keys
      .where((cls) => _processedClasses[cls].isInstantiated);

  // TODO(johnniwinther): Improve semantic precision.
  @override
  Iterable<ClassEntity> get directlyInstantiatedClasses {
    return _directlyInstantiatedClasses;
  }

  /// Register [type] as (directly) instantiated.
  // TODO(johnniwinther): Fully enforce the separation between exact, through
  // subclass and through subtype instantiated types/classes.
  // TODO(johnniwinther): Support unknown type arguments for generic types.
  void registerTypeInstantiation(
      InterfaceType type, ClassUsedCallback classUsed) {
    ClassEntity cls = type.element;
    bool isNative = _nativeBasicData.isNativeClass(cls);
    _instantiatedTypes.add(type);
    // We can't use the closed-world assumption with native abstract
    // classes; a native abstract class may have non-abstract subclasses
    // not declared to the program.  Instances of these classes are
    // indistinguishable from the abstract class.
    if (!cls.isAbstract || isNative) {
      _directlyInstantiatedClasses.add(cls);
      _processInstantiatedClass(cls, classUsed);
    }

    // TODO(johnniwinther): Replace this by separate more specific mappings that
    // include the type arguments.
    if (_implementedClasses.add(cls)) {
      classUsed(cls, _getClassUsage(cls).implement());
      _elementEnvironment.forEachSupertype(cls, (InterfaceType supertype) {
        if (_implementedClasses.add(supertype.element)) {
          classUsed(
              supertype.element, _getClassUsage(supertype.element).implement());
        }
      });
    }
  }

  bool _hasMatchingSelector(Map<Selector, SelectorConstraints> selectors,
      MemberEntity member, JClosedWorld world) {
    if (selectors == null) return false;
    for (Selector selector in selectors.keys) {
      if (selector.appliesUnnamed(member)) {
        SelectorConstraints masks = selectors[selector];
        if (masks.canHit(member, selector.memberName, world)) {
          return true;
        }
      }
    }
    return false;
  }

  bool hasInvocation(MemberEntity member) {
    return _hasMatchingSelector(
        _invokedNames[member.name], member, _closedWorld);
  }

  bool hasInvokedGetter(MemberEntity member) {
    return _hasMatchingSelector(
            _invokedGetters[member.name], member, _closedWorld) ||
        member.isFunction && _methodsNeedingSuperGetter.contains(member);
  }

  bool hasInvokedSetter(MemberEntity member) {
    return _hasMatchingSelector(
        _invokedSetters[member.name], member, _closedWorld);
  }

  bool registerDynamicUse(
      DynamicUse dynamicUse, MemberUsedCallback memberUsed) {
    Selector selector = dynamicUse.selector;
    String methodName = selector.name;

    void _process(Map<String, Set<MemberUsage>> memberMap,
        EnumSet<MemberUse> action(MemberUsage usage)) {
      _processSet(memberMap, methodName, (MemberUsage usage) {
        if (selector.appliesUnnamed(usage.entity) &&
            _selectorConstraintsStrategy.appliedUnnamed(
                dynamicUse, usage.entity, _closedWorld)) {
          memberUsed(usage.entity, action(usage));
          return true;
        }
        return false;
      });
    }

    switch (dynamicUse.kind) {
      case DynamicUseKind.INVOKE:
        registerDynamicInvocation(
            dynamicUse.selector, dynamicUse.typeArguments);
        if (_registerNewSelector(dynamicUse, _invokedNames)) {
          // We don't track parameters in the codegen world builder, so we
          // pass `null` instead of the concrete call structure.
          _process(_instanceMembersByName, (m) => m.invoke(null));
          return true;
        }
        break;
      case DynamicUseKind.GET:
        if (_registerNewSelector(dynamicUse, _invokedGetters)) {
          _process(_instanceMembersByName, (m) => m.read());
          _process(_instanceFunctionsByName, (m) => m.read());
          return true;
        }
        break;
      case DynamicUseKind.SET:
        if (_registerNewSelector(dynamicUse, _invokedSetters)) {
          _process(_instanceMembersByName, (m) => m.write());
          return true;
        }
        break;
    }
    return false;
  }

  bool _registerNewSelector(DynamicUse dynamicUse,
      Map<String, Map<Selector, SelectorConstraints>> selectorMap) {
    Selector selector = dynamicUse.selector;
    String name = selector.name;
    Object constraint = dynamicUse.receiverConstraint;
    Map<Selector, SelectorConstraints> selectors =
        selectorMap[name] ??= new Maplet<Selector, SelectorConstraints>();
    UniverseSelectorConstraints constraints = selectors[selector];
    if (constraints == null) {
      selectors[selector] = _selectorConstraintsStrategy
          .createSelectorConstraints(selector, constraint);
      return true;
    }
    return constraints.addReceiverConstraint(constraint);
  }

  void registerIsCheck(covariant DartType type) {
    _isChecks.add(type.unaliased);
  }

  void registerStaticUse(StaticUse staticUse, MemberUsedCallback memberUsed) {
    MemberEntity element = staticUse.element;
    if (element is FieldEntity) {
      if (element.isTopLevel || element.isStatic) {
        _allReferencedStaticFields.add(element);
      }
    }

    EnumSet<MemberUse> useSet = new EnumSet<MemberUse>();
    MemberUsage usage = _getMemberUsage(element, useSet);
    switch (staticUse.kind) {
      case StaticUseKind.STATIC_TEAR_OFF:
        closurizedStatics.add(element);
        useSet.addAll(usage.read());
        break;
      case StaticUseKind.FIELD_GET:
      case StaticUseKind.FIELD_SET:
      case StaticUseKind.CALL_METHOD:
        // TODO(johnniwinther): Avoid this. Currently [FIELD_GET] and
        // [FIELD_SET] contains [BoxFieldElement]s which we cannot enqueue.
        // Also [CLOSURE] contains [LocalFunctionElement] which we cannot
        // enqueue.
        break;
      case StaticUseKind.INVOKE:
        registerStaticInvocation(staticUse);
        // We don't track parameters in the codegen world builder, so we
        // pass `null` instead of the concrete call structure.
        useSet.addAll(usage.invoke(null));
        break;
      case StaticUseKind.SUPER_FIELD_SET:
      case StaticUseKind.SET:
        useSet.addAll(usage.write());
        break;
      case StaticUseKind.SUPER_TEAR_OFF:
        _methodsNeedingSuperGetter.add(element);
        useSet.addAll(usage.read());
        break;
      case StaticUseKind.GET:
        useSet.addAll(usage.read());
        break;
      case StaticUseKind.FIELD_INIT:
        useSet.addAll(usage.init());
        break;
      case StaticUseKind.FIELD_CONSTANT_INIT:
        useSet.addAll(usage.constantInit(staticUse.constant));
        break;
      case StaticUseKind.CONSTRUCTOR_INVOKE:
      case StaticUseKind.CONST_CONSTRUCTOR_INVOKE:
        // We don't track parameters in the codegen world builder, so we
        // pass `null` instead of the concrete call structure.
        useSet.addAll(usage.invoke(null));
        break;
      case StaticUseKind.DIRECT_INVOKE:
        MemberEntity member = staticUse.element;
        // We don't track parameters in the codegen world builder, so we
        // pass `null` instead of the concrete call structure.
        useSet.addAll(usage.invoke(null));
        _instanceMembersByName[usage.entity.name]?.remove(usage);
        if (staticUse.typeArguments?.isNotEmpty ?? false) {
          registerDynamicInvocation(
              new Selector.call(member.memberName, staticUse.callStructure),
              staticUse.typeArguments);
        }
        break;
      case StaticUseKind.INLINING:
        registerStaticInvocation(staticUse);
        break;
      case StaticUseKind.CLOSURE:
      case StaticUseKind.CLOSURE_CALL:
        failedAt(CURRENT_ELEMENT_SPANNABLE,
            "Static use ${staticUse.kind} is not supported during codegen.");
    }
    if (useSet.isNotEmpty) {
      memberUsed(usage.entity, useSet);
    }
  }

  /// Registers that [element] has been closurized.
  void registerClosurizedMember(MemberEntity element) {
    closurizedMembers.add(element);
  }

  void processClassMembers(ClassEntity cls, MemberUsedCallback memberUsed,
      {bool dryRun: false}) {
    _elementEnvironment.forEachClassMember(cls,
        (ClassEntity cls, MemberEntity member) {
      _processInstantiatedClassMember(cls, member, memberUsed, dryRun: dryRun);
    });
  }

  void _processInstantiatedClassMember(
      ClassEntity cls, MemberEntity member, MemberUsedCallback memberUsed,
      {bool dryRun: false}) {
    if (!member.isInstanceMember) return;
    EnumSet<MemberUse> useSet = new EnumSet<MemberUse>();
    _getMemberUsage(member, useSet);
    if (useSet.isNotEmpty) {
      memberUsed(member, useSet);
    }
  }

  MemberUsage _getMemberUsage(MemberEntity member, EnumSet<MemberUse> useSet,
      {bool dryRun: false}) {
    // TODO(johnniwinther): Change [TypeMask] to not apply to a superclass
    // member unless the class has been instantiated. Similar to
    // [StrongModeConstraint].
    MemberUsage usage = _memberUsage[member];
    if (usage == null) {
      if (member.isInstanceMember) {
        String memberName = member.name;
        ClassEntity cls = member.enclosingClass;
        bool isNative = _nativeBasicData.isNativeClass(cls);
        usage = new MemberUsage(member);
        if (member.isField && !isNative) {
          useSet.addAll(usage.init());
        }
        if (member is JSignatureMethod) {
          // We mark signature methods as "always used" to prevent them from being
          // optimized away.
          // TODO(johnniwinther): Make this a part of the regular enqueueing.
          useSet.addAll(usage.invoke(CallStructure.NO_ARGS));
        }

        if (!usage.hasRead && hasInvokedGetter(member)) {
          useSet.addAll(usage.read());
        }
        if (!usage.hasWrite && hasInvokedSetter(member)) {
          useSet.addAll(usage.write());
        }
        if (!usage.hasInvoke && hasInvocation(member)) {
          // We don't track parameters in the codegen world builder, so we
          // pass `null` instead of the concrete call structures.
          useSet.addAll(usage.invoke(null));
        }

        if (!dryRun) {
          if (usage.hasPendingClosurizationUse) {
            // Store the member in [instanceFunctionsByName] to catch
            // getters on the function.
            _instanceFunctionsByName
                .putIfAbsent(usage.entity.name, () => new Set<MemberUsage>())
                .add(usage);
          }
          if (usage.hasPendingNormalUse) {
            // The element is not yet used. Add it to the list of instance
            // members to still be processed.
            _instanceMembersByName
                .putIfAbsent(memberName, () => new Set<MemberUsage>())
                .add(usage);
          }
        }
      } else {
        usage = new MemberUsage(member);
        if (member.isField) {
          useSet.addAll(usage.init());
        }
      }
      if (!dryRun) {
        _memberUsage[member] = usage;
      }
    } else {
      if (dryRun) {
        usage = usage.clone();
      }
    }
    return usage;
  }

  void _processSet(Map<String, Set<MemberUsage>> map, String memberName,
      bool f(MemberUsage e)) {
    Set<MemberUsage> members = map[memberName];
    if (members == null) return;
    // [f] might add elements to [: map[memberName] :] during the loop below
    // so we create a new list for [: map[memberName] :] and prepend the
    // [remaining] members after the loop.
    map[memberName] = new Set<MemberUsage>();
    Set<MemberUsage> remaining = new Set<MemberUsage>();
    for (MemberUsage member in members) {
      if (!f(member)) remaining.add(member);
    }
    map[memberName].addAll(remaining);
  }

  /// Return the canonical [ClassUsage] for [cls].
  ClassUsage _getClassUsage(ClassEntity cls) {
    return _processedClasses.putIfAbsent(cls, () => new ClassUsage(cls));
  }

  void _processInstantiatedClass(ClassEntity cls, ClassUsedCallback classUsed) {
    // Registers [superclass] as instantiated. Returns `true` if it wasn't
    // already instantiated and we therefore have to process its superclass as
    // well.
    bool processClass(ClassEntity superclass) {
      ClassUsage usage = _getClassUsage(superclass);
      if (!usage.isInstantiated) {
        classUsed(usage.cls, usage.instantiate());
        return true;
      }
      return false;
    }

    while (cls != null && processClass(cls)) {
      cls = _elementEnvironment.getSuperClass(cls);
    }
  }

  /// Set of all registered compiled constants.
  final Set<ConstantValue> _compiledConstants = new Set<ConstantValue>();

  Iterable<ConstantValue> get compiledConstantsForTesting => _compiledConstants;

  @override
  void addCompileTimeConstantForEmission(ConstantValue constant) {
    _compiledConstants.add(constant);
  }

  /// Register the constant [use] with this world builder. Returns `true` if
  /// the constant use was new to the world.
  bool registerConstantUse(ConstantUse use) {
    addCompileTimeConstantForEmission(use.value);
    return _constantValues.add(use.value);
  }

  void registerConstTypeLiteral(DartType type) {
    _constTypeLiterals.add(type);
  }

  void registerTypeArgument(DartType type) {
    _liveTypeArguments.add(type);
  }

  @override
  CodegenWorld close() {
    List<FunctionEntity> genericMethods = <FunctionEntity>[];
    List<FunctionEntity> userNoSuchMethods = <FunctionEntity>[];
    List<FunctionEntity> genericInstanceMethods = <FunctionEntity>[];

    void processMemberUse(MemberEntity member, MemberUsage memberUsage) {
      if (member is FunctionEntity && memberUsage.hasUse) {
        if (_elementEnvironment.getFunctionTypeVariables(member).isNotEmpty) {
          genericMethods.add(member);
          if (member.isInstanceMember) {
            genericInstanceMethods.add(member);
          }
        }
        if (member.isInstanceMember &&
            member.name == Identifiers.noSuchMethod_ &&
            !_closedWorld.commonElements
                .isDefaultNoSuchMethodImplementation(member)) {
          userNoSuchMethods.add(member);
        }
      }
    }

    _memberUsage.forEach(processMemberUse);

    return new CodegenWorldImpl(_closedWorld,
        genericInstanceMethods: genericInstanceMethods,
        constTypeLiterals: _constTypeLiterals,
        genericMethods: genericMethods,
        directlyInstantiatedClasses: directlyInstantiatedClasses,
        allReferencedStaticFields: _allReferencedStaticFields,
        typeVariableTypeLiterals: typeVariableTypeLiterals,
        methodsNeedingSuperGetter: _methodsNeedingSuperGetter,
        instantiatedClasses: instantiatedClasses,
        closurizedStatics: closurizedStatics,
        closurizedMembers: closurizedMembers,
        isChecks: _isChecks,
        userNoSuchMethods: userNoSuchMethods,
        instantiatedTypes: _instantiatedTypes,
        liveTypeArguments: _liveTypeArguments,
        compiledConstants: _compiledConstants,
        invokedNames: _invokedNames,
        invokedGetters: _invokedGetters,
        invokedSetters: _invokedSetters,
        staticTypeArgumentDependencies: staticTypeArgumentDependencies,
        dynamicTypeArgumentDependencies: dynamicTypeArgumentDependencies);
  }
}

class CodegenWorldImpl implements CodegenWorld {
  JClosedWorld _closedWorld;

  @override
  final Iterable<FunctionEntity> genericInstanceMethods;

  @override
  final Iterable<DartType> constTypeLiterals;

  @override
  final Iterable<FunctionEntity> genericMethods;

  @override
  final Iterable<ClassEntity> directlyInstantiatedClasses;

  @override
  final Iterable<FieldEntity> allReferencedStaticFields;

  @override
  final Iterable<TypeVariableType> typeVariableTypeLiterals;

  @override
  final Iterable<FunctionEntity> methodsNeedingSuperGetter;

  @override
  final Iterable<ClassEntity> instantiatedClasses;

  @override
  final Iterable<FunctionEntity> closurizedStatics;

  @override
  final Iterable<FunctionEntity> closurizedMembers;

  @override
  final Iterable<DartType> isChecks;

  @override
  final Iterable<FunctionEntity> userNoSuchMethods;

  @override
  final Iterable<InterfaceType> instantiatedTypes;

  @override
  final Iterable<DartType> liveTypeArguments;

  final Iterable<ConstantValue> compiledConstants;

  final Map<String, Map<Selector, SelectorConstraints>> invokedNames;

  final Map<String, Map<Selector, SelectorConstraints>> invokedGetters;

  final Map<String, Map<Selector, SelectorConstraints>> invokedSetters;

  final Map<Entity, Set<DartType>> staticTypeArgumentDependencies;

  final Map<Selector, Set<DartType>> dynamicTypeArgumentDependencies;

  CodegenWorldImpl(this._closedWorld,
      {this.genericInstanceMethods,
      this.constTypeLiterals,
      this.genericMethods,
      this.directlyInstantiatedClasses,
      this.allReferencedStaticFields,
      this.typeVariableTypeLiterals,
      this.methodsNeedingSuperGetter,
      this.instantiatedClasses,
      this.closurizedStatics,
      this.closurizedMembers,
      this.isChecks,
      this.userNoSuchMethods,
      this.instantiatedTypes,
      this.liveTypeArguments,
      this.compiledConstants,
      this.invokedNames,
      this.invokedGetters,
      this.invokedSetters,
      this.staticTypeArgumentDependencies,
      this.dynamicTypeArgumentDependencies});

  @override
  Iterable<Local> get genericLocalFunctions => const [];

  @override
  void forEachStaticTypeArgument(
      void f(Entity function, Set<DartType> typeArguments)) {
    staticTypeArgumentDependencies.forEach(f);
  }

  @override
  void forEachDynamicTypeArgument(
      void f(Selector selector, Set<DartType> typeArguments)) {
    dynamicTypeArgumentDependencies.forEach(f);
  }

  @override
  void forEachInvokedName(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    invokedNames.forEach(f);
  }

  @override
  void forEachInvokedGetter(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    invokedGetters.forEach(f);
  }

  @override
  void forEachInvokedSetter(
      f(String name, Map<Selector, SelectorConstraints> selectors)) {
    invokedSetters.forEach(f);
  }

  bool _hasMatchingSelector(Map<Selector, SelectorConstraints> selectors,
      MemberEntity member, JClosedWorld world) {
    if (selectors == null) return false;
    for (Selector selector in selectors.keys) {
      if (selector.appliesUnnamed(member)) {
        SelectorConstraints masks = selectors[selector];
        if (masks.canHit(member, selector.memberName, world)) {
          return true;
        }
      }
    }
    return false;
  }

  @override
  bool hasInvokedGetter(MemberEntity member) {
    return _hasMatchingSelector(
            invokedGetters[member.name], member, _closedWorld) ||
        member.isFunction && methodsNeedingSuperGetter.contains(member);
  }

  @override
  bool hasInvokedSetter(MemberEntity member) {
    return _hasMatchingSelector(
        invokedSetters[member.name], member, _closedWorld);
  }

  Map<Selector, SelectorConstraints> _asUnmodifiable(
      Map<Selector, SelectorConstraints> map) {
    if (map == null) return null;
    return new UnmodifiableMapView(map);
  }

  @override
  Map<Selector, SelectorConstraints> invocationsByName(String name) {
    return _asUnmodifiable(invokedNames[name]);
  }

  @override
  Map<Selector, SelectorConstraints> getterInvocationsByName(String name) {
    return _asUnmodifiable(invokedGetters[name]);
  }

  @override
  Map<Selector, SelectorConstraints> setterInvocationsByName(String name) {
    return _asUnmodifiable(invokedSetters[name]);
  }

  @override
  List<ConstantValue> getConstantsForEmission(
      [Comparator<ConstantValue> preSortCompare]) {
    // We must emit dependencies before their uses.
    Set<ConstantValue> seenConstants = new Set<ConstantValue>();
    List<ConstantValue> result = new List<ConstantValue>();

    void addConstant(ConstantValue constant) {
      if (!seenConstants.contains(constant)) {
        constant.getDependencies().forEach(addConstant);
        assert(!seenConstants.contains(constant));
        result.add(constant);
        seenConstants.add(constant);
      }
    }

    List<ConstantValue> sorted = compiledConstants.toList();
    if (preSortCompare != null) {
      sorted.sort(preSortCompare);
    }
    sorted.forEach(addConstant);
    return result;
  }
}
