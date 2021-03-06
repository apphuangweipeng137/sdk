// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import '../common.dart';
import '../common_elements.dart';
import '../constants/constant_system.dart' as constant_system;
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/types.dart';
import '../io/code_output.dart';
import '../js/js.dart' as jsAst;
import '../js/js.dart' show js;
import '../js_backend/field_analysis.dart';
import '../js_emitter/code_emitter_task.dart';
import '../options.dart';
import 'field_analysis.dart' show JFieldAnalysis;
import 'js_backend.dart';
import 'runtime_types.dart';

typedef jsAst.Expression _ConstantReferenceGenerator(ConstantValue constant);

typedef jsAst.Expression _ConstantListGenerator(jsAst.Expression array);

/// Generates the JavaScript expressions for constants.
///
/// It uses a given [constantReferenceGenerator] to reference nested constants
/// (if there are some). It is hence up to that function to decide which
/// constants should be inlined or not.
class ConstantEmitter implements ConstantValueVisitor<jsAst.Expression, Null> {
  // Matches blank lines, comment lines and trailing comments that can't be part
  // of a string.
  static final RegExp COMMENT_RE =
      new RegExp(r'''^ *(//.*)?\n|  *//[^''"\n]*$''', multiLine: true);

  final CompilerOptions _options;
  final JCommonElements _commonElements;
  final JElementEnvironment _elementEnvironment;
  final RuntimeTypesNeed _rtiNeed;
  final RuntimeTypesEncoder _rtiEncoder;
  final JFieldAnalysis _fieldAnalysis;
  final CodeEmitterTask _task;
  final _ConstantReferenceGenerator constantReferenceGenerator;
  final _ConstantListGenerator makeConstantList;

  /// The given [constantReferenceGenerator] function must, when invoked with a
  /// constant, either return a reference or return its literal expression if it
  /// can be inlined.
  ConstantEmitter(
      this._options,
      this._commonElements,
      this._elementEnvironment,
      this._rtiNeed,
      this._rtiEncoder,
      this._fieldAnalysis,
      this._task,
      this.constantReferenceGenerator,
      this.makeConstantList);

  Emitter get _emitter => _task.emitter;

  /// Constructs a literal expression that evaluates to the constant. Uses a
  /// canonical name unless the constant can be emitted multiple times (as for
  /// numbers and strings).
  jsAst.Expression generate(ConstantValue constant) {
    return _visit(constant);
  }

  jsAst.Expression _visit(ConstantValue constant) {
    return constant.accept(this, null);
  }

  @override
  jsAst.Expression visitFunction(FunctionConstantValue constant, [_]) {
    throw failedAt(NO_LOCATION_SPANNABLE,
        "The function constant does not need specific JS code.");
  }

  @override
  jsAst.Expression visitNull(NullConstantValue constant, [_]) {
    return new jsAst.LiteralNull();
  }

  @override
  jsAst.Expression visitNonConstant(NonConstantValue constant, [_]) {
    return new jsAst.LiteralNull();
  }

  static final _exponentialRE = new RegExp('^'
      '\([-+]?\)' // 1: sign
      '\([0-9]+\)' // 2: leading digit(s)
      '\(\.\([0-9]*\)\)?' // 4: fraction digits
      'e\([-+]?[0-9]+\)' // 5: exponent with sign
      r'$');

  /// Reduces the size of exponential representations when minification is
  /// enabled.
  ///
  /// Removes the "+" after the exponential sign, and removes the "." before the
  /// "e". For example `1.23e+5` is changed to `123e3`.
  String _shortenExponentialRepresentation(String numberString) {
    Match match = _exponentialRE.firstMatch(numberString);
    if (match == null) return numberString;
    String sign = match[1];
    String leadingDigits = match[2];
    String fractionDigits = match[4];
    int exponent = int.parse(match[5]);
    if (fractionDigits == null) fractionDigits = '';
    exponent -= fractionDigits.length;
    String result = '${sign}${leadingDigits}${fractionDigits}e${exponent}';
    assert(double.parse(result) == double.parse(numberString));
    return result;
  }

  @override
  jsAst.Expression visitInt(IntConstantValue constant, [_]) {
    BigInt value = constant.intValue;
    // Since we are in JavaScript we can shorten long integers to their shorter
    // exponential representation, for example: "1e4" is shorter than "10000".
    //
    // Note that this shortening apparently loses precision for big numbers
    // (like 1234567890123456789012345 which becomes 12345678901234568e8).
    // However, since JavaScript engines represent all numbers as doubles, these
    // digits are lost anyway.
    String representation = value.toString();
    String alternative = null;
    int cutoff = _options.enableMinification ? 10000 : 1e10.toInt();
    if (value.abs() >= new BigInt.from(cutoff)) {
      alternative = _shortenExponentialRepresentation(
          value.toDouble().toStringAsExponential());
    }
    if (alternative != null && alternative.length < representation.length) {
      representation = alternative;
    }
    return new jsAst.LiteralNumber(representation);
  }

  @override
  jsAst.Expression visitDouble(DoubleConstantValue constant, [_]) {
    double value = constant.doubleValue;
    if (value.isNaN) {
      return js("0/0");
    } else if (value == double.infinity) {
      return js("1/0");
    } else if (value == -double.infinity) {
      return js("-1/0");
    } else {
      String shortened = _shortenExponentialRepresentation("$value");
      return new jsAst.LiteralNumber(shortened);
    }
  }

  @override
  jsAst.Expression visitBool(BoolConstantValue constant, [_]) {
    if (_options.enableMinification) {
      if (constant.isTrue) {
        // Use !0 for true.
        return js("!0");
      } else {
        // Use !1 for false.
        return js("!1");
      }
    } else {
      return constant.isTrue ? js('true') : js('false');
    }
  }

  /// Write the contents of the quoted string to a [CodeBuffer] in
  /// a form that is valid as JavaScript string literal content.
  /// The string is assumed quoted by double quote characters.
  @override
  jsAst.Expression visitString(StringConstantValue constant, [_]) {
    return js.escapedString(constant.stringValue, ascii: true);
  }

  @override
  jsAst.Expression visitList(ListConstantValue constant, [_]) {
    List<jsAst.Expression> elements = constant.entries
        .map(constantReferenceGenerator)
        .toList(growable: false);
    jsAst.ArrayInitializer array = new jsAst.ArrayInitializer(elements);
    jsAst.Expression value = makeConstantList(array);
    return maybeAddTypeArguments(constant, constant.type, value);
  }

  @override
  jsAst.Expression visitSet(constant_system.JavaScriptSetConstant constant,
      [_]) {
    InterfaceType sourceType = constant.type;
    ClassEntity classElement = sourceType.element;
    String className = classElement.name;
    if (!identical(classElement, _commonElements.constSetLiteralClass)) {
      failedAt(
          classElement, "Compiler encoutered unexpected set class $className");
    }

    List<jsAst.Expression> arguments = <jsAst.Expression>[
      constantReferenceGenerator(constant.entries),
    ];

    if (_rtiNeed.classNeedsTypeArguments(classElement)) {
      arguments.add(_reifiedTypeArguments(constant, sourceType.typeArguments));
    }

    jsAst.Expression constructor = _emitter.constructorAccess(classElement);
    return new jsAst.New(constructor, arguments);
  }

  @override
  jsAst.Expression visitMap(constant_system.JavaScriptMapConstant constant,
      [_]) {
    jsAst.Expression jsMap() {
      List<jsAst.Property> properties = <jsAst.Property>[];
      for (int i = 0; i < constant.length; i++) {
        StringConstantValue key = constant.keys[i];
        if (key.stringValue ==
            constant_system.JavaScriptMapConstant.PROTO_PROPERTY) {
          continue;
        }

        // Keys in literal maps must be emitted in place.
        jsAst.Literal keyExpression = _visit(key);
        jsAst.Expression valueExpression =
            constantReferenceGenerator(constant.values[i]);
        properties.add(new jsAst.Property(keyExpression, valueExpression));
      }
      return new jsAst.ObjectInitializer(properties);
    }

    jsAst.Expression jsGeneralMap() {
      List<jsAst.Expression> data = <jsAst.Expression>[];
      for (int i = 0; i < constant.keys.length; i++) {
        jsAst.Expression keyExpression =
            constantReferenceGenerator(constant.keys[i]);
        jsAst.Expression valueExpression =
            constantReferenceGenerator(constant.values[i]);
        data.add(keyExpression);
        data.add(valueExpression);
      }
      return new jsAst.ArrayInitializer(data);
    }

    ClassEntity classElement = constant.type.element;
    String className = classElement.name;

    List<jsAst.Expression> arguments = <jsAst.Expression>[];

    // The arguments of the JavaScript constructor for any given Dart class
    // are in the same order as the members of the class element.
    int emittedArgumentCount = 0;
    _elementEnvironment.forEachInstanceField(classElement,
        (ClassEntity enclosing, FieldEntity field) {
      if (_fieldAnalysis.getFieldData(field).isElided) return;
      if (field.name == constant_system.JavaScriptMapConstant.LENGTH_NAME) {
        arguments
            .add(new jsAst.LiteralNumber('${constant.keyList.entries.length}'));
      } else if (field.name ==
          constant_system.JavaScriptMapConstant.JS_OBJECT_NAME) {
        arguments.add(jsMap());
      } else if (field.name ==
          constant_system.JavaScriptMapConstant.KEYS_NAME) {
        arguments.add(constantReferenceGenerator(constant.keyList));
      } else if (field.name ==
          constant_system.JavaScriptMapConstant.PROTO_VALUE) {
        assert(constant.protoValue != null);
        arguments.add(constantReferenceGenerator(constant.protoValue));
      } else if (field.name ==
          constant_system.JavaScriptMapConstant.JS_DATA_NAME) {
        arguments.add(jsGeneralMap());
      } else {
        failedAt(field,
            "Compiler has unexpected field ${field.name} for ${className}.");
      }
      emittedArgumentCount++;
    });
    if ((className == constant_system.JavaScriptMapConstant.DART_STRING_CLASS &&
            emittedArgumentCount != 3) ||
        (className == constant_system.JavaScriptMapConstant.DART_PROTO_CLASS &&
            emittedArgumentCount != 4) ||
        (className ==
                constant_system.JavaScriptMapConstant.DART_GENERAL_CLASS &&
            emittedArgumentCount != 1)) {
      failedAt(classElement,
          "Compiler and ${className} disagree on number of fields.");
    }

    if (_rtiNeed.classNeedsTypeArguments(classElement)) {
      arguments
          .add(_reifiedTypeArguments(constant, constant.type.typeArguments));
    }

    jsAst.Expression constructor = _emitter.constructorAccess(classElement);
    jsAst.Expression value = new jsAst.New(constructor, arguments);
    return value;
  }

  jsAst.PropertyAccess getHelperProperty(FunctionEntity helper) {
    return _emitter.staticFunctionAccess(helper);
  }

  @override
  jsAst.Expression visitType(TypeConstantValue constant, [_]) {
    DartType type = constant.representedType.unaliased;

    jsAst.Expression unexpected(TypeVariableType _variable) {
      TypeVariableType variable = _variable;
      throw failedAt(
          NO_LOCATION_SPANNABLE,
          "Unexpected type variable '${variable}'"
          " in constant '${constant.toDartText()}'");
    }

    jsAst.Expression rti =
        _rtiEncoder.getTypeRepresentation(_emitter, type, unexpected);

    return new jsAst.Call(
        getHelperProperty(_commonElements.createRuntimeType), [rti]);
  }

  @override
  jsAst.Expression visitInterceptor(InterceptorConstantValue constant, [_]) {
    ClassEntity interceptorClass = constant.cls;
    return _task.interceptorPrototypeAccess(interceptorClass);
  }

  @override
  jsAst.Expression visitSynthetic(SyntheticConstantValue constant, [_]) {
    switch (constant.valueKind) {
      case SyntheticConstantKind.DUMMY_INTERCEPTOR:
      case SyntheticConstantKind.EMPTY_VALUE:
        return new jsAst.LiteralNumber('0');
      case SyntheticConstantKind.TYPEVARIABLE_REFERENCE:
      case SyntheticConstantKind.NAME:
        return constant.payload;
      default:
        throw failedAt(NO_LOCATION_SPANNABLE,
            "Unexpected DummyConstantKind ${constant.kind}");
    }
  }

  @override
  jsAst.Expression visitConstructed(ConstructedConstantValue constant, [_]) {
    ClassEntity element = constant.type.element;
    if (element == _commonElements.jsConstClass) {
      StringConstantValue str = constant.fields.values.single;
      String value = str.stringValue;
      return new jsAst.LiteralExpression(stripComments(value));
    }
    jsAst.Expression constructor =
        _emitter.constructorAccess(constant.type.element);
    List<jsAst.Expression> fields = <jsAst.Expression>[];
    _elementEnvironment.forEachInstanceField(element, (_, FieldEntity field) {
      FieldAnalysisData fieldData = _fieldAnalysis.getFieldData(field);
      if (fieldData.isElided) return;
      if (!fieldData.isInitializedInAllocator) {
        fields.add(constantReferenceGenerator(constant.fields[field]));
      }
    });
    if (_rtiNeed.classNeedsTypeArguments(constant.type.element)) {
      fields.add(_reifiedTypeArguments(constant, constant.type.typeArguments));
    }
    return new jsAst.New(constructor, fields);
  }

  @override
  jsAst.Expression visitInstantiation(InstantiationConstantValue constant,
      [_]) {
    ClassEntity cls =
        _commonElements.getInstantiationClass(constant.typeArguments.length);
    List<jsAst.Expression> fields = <jsAst.Expression>[
      constantReferenceGenerator(constant.function),
      _reifiedTypeArguments(constant, constant.typeArguments)
    ];
    jsAst.Expression constructor = _emitter.constructorAccess(cls);
    return new jsAst.New(constructor, fields);
  }

  String stripComments(String rawJavaScript) {
    return rawJavaScript.replaceAll(COMMENT_RE, '');
  }

  jsAst.Expression maybeAddTypeArguments(
      ConstantValue constant, InterfaceType type, jsAst.Expression value) {
    if (type is InterfaceType &&
        !type.treatAsRaw &&
        _rtiNeed.classNeedsTypeArguments(type.element)) {
      return new jsAst.Call(
          getHelperProperty(_commonElements.setRuntimeTypeInfo),
          [value, _reifiedTypeArguments(constant, type.typeArguments)]);
    }
    return value;
  }

  jsAst.Expression _reifiedTypeArguments(
      ConstantValue constant, List<DartType> typeArguments) {
    jsAst.Expression unexpected(TypeVariableType _variable) {
      TypeVariableType variable = _variable;
      throw failedAt(
          NO_LOCATION_SPANNABLE,
          "Unexpected type variable '${variable}'"
          " in constant '${constant.toDartText()}'");
    }

    List<jsAst.Expression> arguments = <jsAst.Expression>[];
    for (DartType argument in typeArguments) {
      arguments.add(
          _rtiEncoder.getTypeRepresentation(_emitter, argument, unexpected));
    }
    return new jsAst.ArrayInitializer(arguments);
  }

  @override
  jsAst.Expression visitDeferredGlobal(DeferredGlobalConstantValue constant,
      [_]) {
    return constantReferenceGenerator(constant.referenced);
  }
}
